local punishMap = require("ai_tournament.punish_map")
local turnEnumerator = require("ai_tournament.turn_enumerator")
local movePatternPenalty = require("ai_tournament.move_pattern_penalty")
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

local function collectContinuationEntries(ai, state, ctx)
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local raw = {}
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions then
        raw = ctx.turnEnumerator.collectTournamentActions(ai, state, playerId, ctx, {
            includeMove = true,
            includeAttack = false,
            includeRepair = true,
            includeDeploy = true
        }) or {}
    elseif ai and ai.collectLegalActions then
        raw = ai:collectLegalActions(state, {
            aiPlayer = playerId,
            includeMove = true,
            includeAttack = false,
            includeRepair = true,
            includeDeploy = true
        }) or {}
    else
        raw = turnEnumerator.collectTournamentActions(ai, state, playerId, ctx, {
            includeMove = true,
            includeAttack = false,
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

local function cellScoreValue(personalityCell, mapCell)
    return num(personalityCell and personalityCell.value, mapCell and mapCell.value or 0)
end

local function smartSecondOrderEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_SMART_ORDER_ENABLED == false)
end

local function prefixTargetCell(prefix)
    local firstAction = prefix and prefix.actions and prefix.actions[1] or nil
    if firstAction and firstAction.target then
        return firstAction.target
    end
    local targetKey = prefix and prefix.midPosition and prefix.midPosition.targetKey or nil
    local row, col = tostring(targetKey or ""):match("^(%-?%d+),(%-?%d+)$")
    if row and col then
        return {row = tonumber(row), col = tonumber(col)}
    end
    return nil
end

local function unitForActionSource(ai, state, ctx, action)
    if not action then
        return nil
    end
    if action.type == "supply_deploy" then
        return {
            name = action.unitName or action.unitType or (action.unit and action.unit.name),
            player = ctx and ctx.aiPlayer,
            atkRange = action.atkRange or action.attackRange,
            currentHp = action.currentHp or action.startingHp,
            startingHp = action.startingHp or action.currentHp
        }
    end
    if action.unit then
        return getUnitAt(ai, state, action.unit.row, action.unit.col) or action.unit
    end
    return nil
end

local function canCoverPrefix(ai, state, action, unit, prefix)
    if not (state and action and action.target and unit) then
        return false
    end
    if action.type ~= "move" and action.type ~= "supply_deploy" then
        return false
    end
    local targetCell = prefixTargetCell(prefix)
    local canAttack = punishMap and punishMap._private and punishMap._private.canAttackCellFrom
    if not (targetCell and canAttack) then
        return false
    end
    return canAttack(ai, state, unit, action.target, targetCell, {allowEmptyTarget = true}) == true
end

local function prefixCoverBonus(ctx, prefix)
    if not smartSecondOrderEnabled(ctx) then
        return 0
    end
    local position = prefix and prefix.midPosition or nil
    local bonus = num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_COVER_PREFIX_BONUS, 420)
    if position and position.covered ~= true then
        bonus = bonus + num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_UNCOVERED_PREFIX_BONUS, 140)
    end
    local damage = num(position and position.exposureDamage, 0)
    if damage > 0 then
        bonus = bonus + math.min(360, damage * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_EXPOSED_PREFIX_WEIGHT, 80))
    end
    return bonus
end

local function drawCoverStallPenalty(ctx, drawDetails, coverBonus)
    if not drawDetails then
        return 0
    end
    if num(drawDetails.remainingBeforeLimit, 99) > 1 then
        return 0
    end
    local progress = tonumber(drawDetails.progress)
    if progress and progress > 0 then
        return 0
    end
    local limit = math.max(0, num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_COVER_STALL_PENALTY, 900))
    return math.min(math.max(0, num(coverBonus, 0)), limit)
end

local function pressureDelta(ctx, midMap, action)
    local targetPersonality, targetMap = targetCell(ctx, midMap, action)
    local sourcePersonality, sourceMap = sourceCell(ctx, midMap, action)
    local targetValue = cellScoreValue(targetPersonality, targetMap)
    local sourceValue = cellScoreValue(sourcePersonality, sourceMap)
    return targetValue - math.max(0, sourceValue), targetValue, sourceValue
end

local function drawNoLegalCombat(ctx)
    local stats = ctx and ctx.stats or nil
    if not stats then
        return false
    end
    if stats.legalAttackActions == nil or stats.legalMoveAttackActions == nil then
        return false
    end
    return num(stats.legalAttackActions, 0) <= 0
        and num(stats.legalMoveAttackActions, 0) <= 0
end

local function drawWaveScale(ctx, draw)
    if ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_WAVE_ENABLED == false then
        return 1
    end
    if not (draw and draw.active == true and draw.pressureLimit == true) then
        return 1
    end
    return 1
        + num(draw.urgency, 0) * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_WAVE_URGENCY_WEIGHT, 0.75)
        + num(draw.urgencyRatio, 0) * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_WAVE_RATIO_WEIGHT, 1.25)
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

local function manhattan(a, b)
    if not (a and b) then
        return nil
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function closestEnemyDistance(ai, state, playerId, enemyPlayer, fromCell)
    if not (state and fromCell and playerId and enemyPlayer) then
        return nil
    end
    local best = nil
    for _, unit in ipairs(state.units or {}) do
        if unit
            and num(unit.player, -999) == num(enemyPlayer, -998)
            and isAlive(unit)
            and not isObstacle(ai, unit)
            and not isHub(ai, unit) then
            local distance = manhattan(fromCell, unit)
            if distance and (best == nil or distance < best) then
                best = distance
            end
        end
    end
    return best
end

local function actionApproachProgress(ai, state, ctx, action)
    if not (action and action.unit and action.target) then
        return nil
    end
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer
    local enemyPlayer = enemyPlayerFor(ai, state, ctx, playerId)
    local beforeDistance = closestEnemyDistance(ai, state, playerId, enemyPlayer, action.unit)
    local afterDistance = closestEnemyDistance(ai, state, playerId, enemyPlayer, action.target)
    if beforeDistance == nil or afterDistance == nil then
        return nil
    end
    return beforeDistance - afterDistance
end

local function drawSecondPressureScore(ai, beforeSecondState, ctx, action)
    if not drawNoLegalCombat(ctx) then
        return 0, nil
    end
    local draw = drawPressure.build(ai, beforeSecondState, ctx)
    if not (draw and draw.active == true and draw.pressureLimit == true) then
        return 0, nil
    end

    local actionType = action and action.type or "unknown"
    local wave = drawWaveScale(ctx, draw)
    local score = 0
    local progress = nil
    local reason = nil
    if actionType == "move" then
        progress = actionApproachProgress(ai, beforeSecondState, ctx, action)
        if progress and progress > 0 then
            score = progress * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_SECOND_APPROACH_BONUS, 520) * wave
            reason = "draw_second_approach"
        elseif progress == 0 then
            score = -num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_SECOND_STAGNATION_PENALTY, 340) * wave
            reason = "draw_second_stagnation"
        elseif progress then
            score = progress * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_SECOND_RETREAT_PENALTY, 620) * wave
            reason = "draw_second_retreat"
        end
    elseif actionType == "supply_deploy" then
        local ratio = math.max(0, math.min(1, num(draw.urgencyRatio, 0)))
        local minScale = math.max(0, num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_DEPLOY_PRESSURE_SCALE_MIN, 0.35))
        local scale = math.min(1, minScale + (1 - minScale) * ratio)
        score = -num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_DEPLOY_STALL_PENALTY, 9000) * scale
        reason = "draw_second_deploy_stall"
    elseif actionType == "repair" or actionType == "skip" then
        score = -num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_SECOND_STAGNATION_PENALTY, 340) * wave
        reason = "draw_second_stagnation"
    end

    if reason then
        return score, {
            reason = reason,
            progress = progress,
            wave = wave,
            urgency = draw.urgency,
            urgencyRatio = draw.urgencyRatio,
            remainingBeforeLimit = draw.remainingBeforeLimit
        }
    end
    return 0, nil
end

local function preScoreSecondAction(ai, afterPrefix, ctx, midMap, prefix, entry)
    local action = entry and entry.action or nil
    local actionType = action and action.type or "unknown"
    local delta, targetValue = pressureDelta(ctx, midMap, action)
    local score = num(entry and entry.cheapScore, 0)
        + targetValue * 0.55
        + delta * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_PRESSURE_DELTA_WEIGHT, 0.30)
    local drawScore, drawDetails = drawSecondPressureScore(ai, afterPrefix, ctx, action)
    score = score + drawScore
    if actionType == "move" then
        score = score + 95
    elseif actionType == "supply_deploy" then
        score = score + 125
    elseif actionType == "repair" then
        score = score + 100
    end

    local unit = unitForActionSource(ai, afterPrefix, ctx, action)
    if smartSecondOrderEnabled(ctx) and canCoverPrefix(ai, afterPrefix, action, unit, prefix) then
        local coverBonus = prefixCoverBonus(ctx, prefix)
        score = score + coverBonus - drawCoverStallPenalty(ctx, drawDetails, coverBonus)
    end
    score = movePatternPenalty.adjustScore(ai, afterPrefix, ctx, action, score)
    return score
end

local function unitForAction(ai, afterState, action)
    if not (afterState and action and action.target) then
        return nil
    end
    if action.type ~= "move" and action.type ~= "supply_deploy" then
        return nil
    end
    local unit = getUnitAt(ai, afterState, action.target.row, action.target.col)
    if not unit then
        return nil
    end
    return unit
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

local function mapExposure(ctx, midMap, action, unit)
    local personalityCell, mapCell = targetCell(ctx, midMap, action)
    local punish = mapCell and mapCell.enemyPunish or nil
    local damage = num(punish and punish.damage, 0)
    local lethal = (punish and punish.lethal == true)
        or (damage > 0 and unit and damage >= unitHp(unit))
        or (personalityCell and personalityCell.riskBand == "lethal_bad_trade")
    return {
        enemyBestReply = punish,
        covered = mapCell and mapCell.coveredIfOccupied == true,
        damage = damage,
        lethal = lethal,
        riskBand = personalityCell and personalityCell.riskBand or nil
    }
end

local function exposureForAction(ai, afterState, ctx, midMap, action)
    local unit = unitForAction(ai, afterState, action)
    if not unit then
        return nil, nil
    end
    if useDynamicExposure(ctx) then
        return punishMap.analyzeCell(afterState, ai, ctx, unit, unit), unit
    end
    return mapExposure(ctx, midMap, action, unit), unit
end

local function scoreSecondAction(ai, beforeSecondState, ctx, midMap, prefix, entry, afterState, exposure, unit)
    local _afterState = afterState
    local action = entry and entry.action or nil
    local actionType = action and action.type or "unknown"
    local personalityCell, mapCell = targetCell(ctx, midMap, action)
    local cellValue = cellScoreValue(personalityCell, mapCell)
    local delta, _, sourceValue = pressureDelta(ctx, midMap, action)
    local damage = exposureDamage(exposure)
    local lethal = exposure and lethalExposure(exposure, unit) == true
    local lethalPenalty = lethal and num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DESTINATION_LETHAL_PENALTY, 70000) or 0
    local coveredBonus = exposure and exposure.covered == true and 55 or 0
    local coversPrefix = smartSecondOrderEnabled(ctx) and canCoverPrefix(ai, _afterState, action, unit, prefix)
    local drawScore, drawDetails = drawSecondPressureScore(ai, beforeSecondState, ctx, action)
    local rawCoverPrefixBonus = coversPrefix and prefixCoverBonus(ctx, prefix) or 0
    local coverStallPenalty = drawCoverStallPenalty(ctx, drawDetails, rawCoverPrefixBonus)
    local coverPrefixBonus = rawCoverPrefixBonus - coverStallPenalty
    local deltaWeight = smartSecondOrderEnabled(ctx)
        and num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_PRESSURE_DELTA_WEIGHT, 0.30)
        or 0
    local actionBonus = 0
    if actionType == "move" then
        actionBonus = 95
    elseif actionType == "supply_deploy" then
        actionBonus = 125
    elseif actionType == "repair" then
        actionBonus = 100
    end
    local score = num(entry and entry.cheapScore, 0)
        + cellValue * 0.55
        + delta * deltaWeight
        + actionBonus
        + coveredBonus
        + coverPrefixBonus
        + drawScore
        - damage * 95
        - lethalPenalty
    score = movePatternPenalty.adjustScore(ai, beforeSecondState, ctx, action, score, ctx and ctx.stats)
    return score,
        {
            reason = coversPrefix and "mid_second_cover_prefix" or ("mid_second_" .. tostring(actionType)),
            coversPrefix = coversPrefix,
            drawCoverStallPenalty = coverStallPenalty,
            pressureDelta = delta,
            targetValue = cellValue,
            sourceValue = sourceValue,
            drawPressureScore = drawScore,
            drawPressure = drawDetails
        }
end

local function mergePosition(prefixPosition, secondReason, secondScore, secondExposure, secondUnit, details)
    local out = {}
    for key, value in pairs(prefixPosition or {}) do
        out[key] = value
    end
    out.score = num(prefixPosition and prefixPosition.score, 0) + num(secondScore, 0)
    out.secondReason = secondReason
    out.secondExposureDamage = exposureDamage(secondExposure)
    out.secondLethalExposure = secondExposure and lethalExposure(secondExposure, secondUnit) == true or false
    out.secondCovered = secondExposure and secondExposure.covered == true or nil
    out.secondUnitName = secondUnit and secondUnit.name or nil
    out.secondCoversPrefix = details and details.coversPrefix == true or false
    out.secondPressureDelta = details and details.pressureDelta or nil
    out.secondTargetValue = details and details.targetValue or nil
    out.secondSourceValue = details and details.sourceValue or nil
    out.secondDrawPressureScore = details and details.drawPressureScore or nil
    out.secondDrawPressure = details and details.drawPressure or nil
    out.secondDrawCoverStallPenalty = details and details.drawCoverStallPenalty or nil
    if out.secondLethalExposure then
        out.destinationExposureLethal = true
        out.destinationExposurePenalty = math.max(
            num(out.destinationExposurePenalty, 0),
            num(prefixPosition and prefixPosition.destinationExposurePenalty, 0)
        )
    end
    out.reason = tostring(prefixPosition and prefixPosition.reason or "mid_position_pressure")
        .. "_then_" .. tostring(secondReason or "position")
    return out
end

local function annotateCandidate(ctx, prefix, secondEntry, afterState, secondScore, secondExposure, secondUnit, secondReason, details)
    local actions = copyArray(prefix.actions or {})
    actions[#actions + 1] = copyAction(secondEntry.action)
    movePatternPenalty.tagPositionMoves(actions)
    local secondType = secondEntry.action and secondEntry.action.type or "unknown"
    local midPosition = mergePosition(prefix.midPosition, secondReason or ("mid_second_" .. secondType), secondScore, secondExposure, secondUnit, details)
    local candidate = {
        actions = actions,
        signature = sequenceSignature(ctx, actions),
        source = "mid_v2_position",
        buckets = prefix.buckets or {"mid_position"},
        cheapScore = num(prefix.cheapScore, 0) + num(secondScore, 0),
        tacticalTags = {},
        containsDeploy = prefix.containsDeploy == true or secondType == "supply_deploy",
        containsAttack = false,
        completeTurn = true,
        terminal = false,
        legalSkipReason = nil,
        midPosition = midPosition,
        _midAfterState = afterState
    }
    for key, value in pairs(prefix.tacticalTags or {}) do
        candidate.tacticalTags[key] = value
    end
    candidate.tacticalTags.midSecondAction = secondType
    candidate.tacticalTags.midSecondCoversPrefix = details and details.coversPrefix == true or nil
    candidate.tacticalTags.midSecondPressureDelta = details and details.pressureDelta or nil
    candidate.tacticalTags.midSecondDrawPressureScore = details and details.drawPressureScore or nil
    candidate.tacticalTags.midSecondDrawCoverStallPenalty = details and details.drawCoverStallPenalty or nil
    return candidate
end

function M.complete(ai, state, ctx, midMap, prefix, options)
    options = options or {}
    local stats = ctx and ctx.stats or nil
    if stats then
        stats.pipelineV2MidPositionSecondPrefixes = num(stats.pipelineV2MidPositionSecondPrefixes, 0) + 1
        stats.pipelineV2MidPositionSecondRejectedReasons =
            stats.pipelineV2MidPositionSecondRejectedReasons or {}
    end

    if not (ai and state and ctx and prefix and prefix.actions and #prefix.actions > 0) then
        if stats then
            bumpReason(stats.pipelineV2MidPositionSecondRejectedReasons, "missing_prefix")
        end
        return {}
    end

    local afterPrefix = prefix._midAfterState or simulate(ai, state, ctx, prefix.actions)
    if not afterPrefix then
        if stats then
            bumpReason(stats.pipelineV2MidPositionSecondRejectedReasons, "prefix_simulation_failed")
        end
        return {}
    end

    local entries = collectContinuationEntries(ai, afterPrefix, ctx)
    if stats then
        stats.pipelineV2MidPositionSecondLegalActions =
            num(stats.pipelineV2MidPositionSecondLegalActions, 0) + #entries
    end
    if #entries == 0 then
        if stats then
            bumpReason(stats.pipelineV2MidPositionSecondRejectedReasons, "no_second_action")
        end
        return {}
    end

    if smartSecondOrderEnabled(ctx) then
        table.sort(entries, function(a, b)
            local av = preScoreSecondAction(ai, afterPrefix, ctx, midMap, prefix, a)
            local bv = preScoreSecondAction(ai, afterPrefix, ctx, midMap, prefix, b)
            if av == bv then
                return tostring(a and a.signature or "") < tostring(b and b.signature or "")
            end
            return av > bv
        end)
    end

    local scanCap = clampLimit(
        options.scanCap or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_SCAN_CAP) or 3,
        1,
        60
    )
    local maxCompletions = clampLimit(
        options.maxCompletions or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_COMPLETION_CAP) or 1,
        1,
        12
    )

    local prepared = {}
    local scanned = 0
    for _, entry in ipairs(entries) do
        if scanned >= scanCap then
            break
        end
        if ctx.shouldStop and ctx.shouldStop() then
            if stats then
                stats.pipelineV2MidPositionSecondStopped = true
            end
            break
        end
        scanned = scanned + 1

        local actions = copyArray(prefix.actions)
        actions[#actions + 1] = copyAction(entry.action)
        local afterFull = simulate(ai, state, ctx, actions)
        if afterFull then
            local secondExposure, secondUnit = exposureForAction(ai, afterFull, ctx, midMap, entry.action)
            if secondExposure and lethalExposure(secondExposure, secondUnit) then
                if stats then
                    bumpReason(stats.pipelineV2MidPositionSecondRejectedReasons, "second_lethal_exposure_penalized")
                end
            end
            local score, details = scoreSecondAction(
                ai,
                afterPrefix,
                ctx,
                midMap,
                prefix,
                entry,
                afterFull,
                secondExposure,
                secondUnit
            )
            if stats then
                stats.pipelineV2MidPositionSecondReasonCounts =
                    stats.pipelineV2MidPositionSecondReasonCounts or {}
                bumpReason(stats.pipelineV2MidPositionSecondReasonCounts, details and details.reason)
            end
            prepared[#prepared + 1] = {
                entry = entry,
                afterState = afterFull,
                score = score,
                exposure = secondExposure,
                unit = secondUnit,
                reason = details and details.reason or nil,
                details = details
            }
        elseif stats then
            bumpReason(stats.pipelineV2MidPositionSecondRejectedReasons, "second_simulation_failed")
        end
        if stats then
            stats.pipelineV2MidPositionSecondEvaluated =
                num(stats.pipelineV2MidPositionSecondEvaluated, 0) + 1
        end
    end

    table.sort(prepared, function(a, b)
        if num(a and a.score, 0) == num(b and b.score, 0) then
            return tostring(a and a.entry and a.entry.signature or "")
                < tostring(b and b.entry and b.entry.signature or "")
        end
        return num(a and a.score, 0) > num(b and b.score, 0)
    end)

    local out = {}
    for index, item in ipairs(prepared) do
        if index > maxCompletions then
            break
        end
        out[#out + 1] = annotateCandidate(
            ctx,
            prefix,
            item.entry,
            item.afterState,
            item.score,
            item.exposure,
            item.unit,
            item.reason,
            item.details
        )
    end

    if stats then
        stats.pipelineV2MidPositionSecondScanned =
            num(stats.pipelineV2MidPositionSecondScanned, 0) + scanned
        stats.pipelineV2MidPositionSecondCompleted =
            num(stats.pipelineV2MidPositionSecondCompleted, 0) + #out
        if #out == 0 then
            bumpReason(stats.pipelineV2MidPositionSecondRejectedReasons, "no_accepted_completion")
        end
    end

    return out
end

return M
