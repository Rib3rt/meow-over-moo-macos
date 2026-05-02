local deployBudget = require("ai_tournament.pipeline_v2_deploy_budget")
local midPositionSecondAction = require("ai_tournament.mid_position_second_action")
local turnEnumerator = require("ai_tournament.turn_enumerator")

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

local function copyArray(items)
    local out = {}
    for index, item in ipairs(items or {}) do
        out[index] = copyAction(item)
    end
    return out
end

local function copyMap(map)
    local out = {}
    for key, value in pairs(map or {}) do
        out[key] = value
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
    if row == nil or col == nil then
        return nil
    end
    return tostring(num(row, 0)) .. "," .. tostring(num(col, 0))
end

local function sequenceSignature(ctx, actions)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.sequenceSignature then
        return ctx.turnEnumerator.sequenceSignature(actions)
    end
    return turnEnumerator.sequenceSignature(actions)
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

local function firstOwnUnitCell(state, playerId)
    for _, unit in ipairs(state and state.units or {}) do
        if unit and unit.player == playerId and unit.row and unit.col then
            return {row = unit.row, col = unit.col}
        end
    end
    return {row = 1, col = 1}
end

local function unitHp(unit)
    return num(unit and (unit.currentHp or unit.startingHp), 0)
end

local function targetCell(ctx, midMap, action)
    local key = cellKey(action and action.target)
    local personalityCell = ctx
        and ctx.midPersonality
        and ctx.midPersonality.byKey
        and ctx.midPersonality.byKey[key]
        or nil
    local mapCell = midMap and midMap.byKey and midMap.byKey[key] or nil
    return personalityCell, mapCell, key
end

local function deployRoleScore(ctx, action)
    local name = tostring(action and (action.unitName or action.unitType) or "")
    local cfg = ctx and ctx.cfg or {}
    if name == "Cloudstriker" or name == "Artillery" then
        return num(cfg.PIPELINE_V2_MID_DEPLOY_RANGED_ROLE_BONUS, 240)
    end
    if name == "Earthstalker" or name == "Crusher" then
        return num(cfg.PIPELINE_V2_MID_DEPLOY_COMBAT_ROLE_BONUS, 180)
    end
    if name == "Bastion" then
        return num(cfg.PIPELINE_V2_MID_DEPLOY_ANCHOR_ROLE_BONUS, 120)
    end
    if name == "Healer" then
        return -num(cfg.PIPELINE_V2_MID_DEPLOY_PASSIVE_ROLE_PENALTY, 80)
    end
    return 0
end

local function exposureForDeploy(ctx, personalityCell, mapCell, deployed)
    local punish = mapCell and mapCell.enemyPunish or nil
    local damage = num(punish and punish.damage, 0)
    local lethal = (punish and punish.lethal == true)
        or (damage > 0 and deployed and damage >= unitHp(deployed))
        or (personalityCell and personalityCell.riskBand == "lethal_bad_trade")
    local lethalPenalty = lethal and num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DEPLOY_LETHAL_PENALTY, 70000) or 0
    return damage, lethal, lethalPenalty
end

local function evaluateDeploy(ai, state, ctx, midMap, entry)
    local action = copyAction(entry and entry.action)
    if not (action and action.type == "supply_deploy" and action.target) then
        return nil, "mid_deploy_missing_action"
    end

    local personalityCell, mapCell, targetKey = targetCell(ctx, midMap, action)
    local targetValue = num(personalityCell and personalityCell.value, mapCell and mapCell.value or 0)
    local roleScore = deployRoleScore(ctx, action)
    local afterDeploy = ctx and ctx.cache and ctx.cache.simulate
        and ctx.cache.simulate(ai, state, {action}, ctx.aiPlayer, ctx)
        or nil
    if not afterDeploy then
        return nil, "mid_deploy_simulation_failed"
    end
    local deployed = getUnitAt(ai, afterDeploy, action.target.row, action.target.col)
    local damage, lethal, lethalPenalty = exposureForDeploy(ctx, personalityCell, mapCell, deployed)
    local damagePenalty = damage * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DEPLOY_DAMAGE_PENALTY, 85)
    local score = targetValue
        + roleScore
        + num(entry and entry.cheapScore, 0) * 0.08
        - damagePenalty
        - lethalPenalty
    local reason = lethal and "mid_deploy_lethal_pressure"
        or (damage > 0 and "mid_deploy_nonlethal_pressure" or "mid_deploy_staging")

    return {
        action = action,
        afterState = afterDeploy,
        score = score,
        targetKey = targetKey,
        targetValue = targetValue,
        roleScore = roleScore,
        exposureDamage = damage,
        lethalExposure = lethal,
        destinationExposurePenalty = lethalPenalty,
        intent = personalityCell and personalityCell.intent or "deploy",
        riskBand = personalityCell and personalityCell.riskBand or "stable",
        reason = reason
    }, nil
end

local function makePrefix(ctx, evaluated)
    local action = evaluated.action
    local actions = {action}
    return {
        actions = actions,
        signature = sequenceSignature(ctx, actions),
        source = "mid_v2_deploy",
        buckets = {"mid_deploy", "mid_position"},
        cheapScore = num(evaluated.score, 0),
        tacticalTags = {
            midV2 = true,
            midPosition = true,
            midDeploy = true,
            midTargetKey = evaluated.targetKey,
            midTargetValue = evaluated.targetValue,
            midPositionReason = evaluated.reason,
            midPositionIntent = evaluated.intent,
            midPositionRiskBand = evaluated.riskBand
        },
        containsDeploy = true,
        containsAttack = false,
        completeTurn = false,
        terminal = false,
        legalSkipReason = nil,
        midPosition = {
            accepted = true,
            class = "deploy",
            reason = evaluated.reason,
            score = evaluated.score,
            targetKey = evaluated.targetKey,
            targetValue = evaluated.targetValue,
            sourceValue = 0,
            pressureGain = evaluated.targetValue,
            exposureDamage = evaluated.exposureDamage,
            lethalExposure = evaluated.lethalExposure == true,
            destinationExposurePenalty = evaluated.destinationExposurePenalty,
            covered = nil,
            intent = evaluated.intent,
            riskBand = evaluated.riskBand
        },
        _midAfterState = evaluated.afterState
    }
end

local function makeDeploySkipCandidate(ctx, prefix)
    local afterPrefix = prefix and prefix._midAfterState or nil
    local penalty = num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DEPLOY_SKIP_SECOND_PENALTY, 120)
    local actions = copyArray(prefix and prefix.actions or {})
    actions[#actions + 1] = {
        type = "skip",
        unit = firstOwnUnitCell(afterPrefix, ctx and ctx.aiPlayer or nil),
        target = {row = 0, col = 0}
    }

    local midPosition = copyMap(prefix and prefix.midPosition or {})
    local baseReason = tostring(midPosition.reason or "mid_deploy_staging")
    midPosition.score = num(midPosition.score, 0) - penalty
    midPosition.secondReason = "mid_second_skip"
    midPosition.secondExposureDamage = 0
    midPosition.secondLethalExposure = false
    midPosition.secondCovered = nil
    midPosition.secondCoversPrefix = false
    midPosition.reason = baseReason .. "_then_mid_second_skip"

    local tags = copyMap(prefix and prefix.tacticalTags or {})
    tags.midDeploy = true
    tags.midDeploySkipCompletion = true
    tags.midSecondAction = "skip"

    return {
        actions = actions,
        signature = sequenceSignature(ctx, actions),
        source = "mid_v2_deploy",
        buckets = {"mid_deploy", "mid_position"},
        cheapScore = num(prefix and prefix.cheapScore, 0) - penalty,
        tacticalTags = tags,
        containsDeploy = true,
        containsAttack = false,
        completeTurn = true,
        terminal = false,
        legalSkipReason = "mid_deploy_no_second_action",
        midPosition = midPosition,
        _midAfterState = afterPrefix
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
        stats.pipelineV2MidDeployCandidates = 0
        stats.pipelineV2MidDeployEvaluated = 0
        stats.pipelineV2MidDeployRejectedReasons = {}
        stats.pipelineV2MidDeployTop = {}
    end

    if not (ai and state and ctx and midMap) then
        return {}
    end
    if ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DEPLOY_CANDIDATES_ENABLED == false then
        if stats then
            stats.pipelineV2MidDeploySkippedReason = "disabled"
        end
        return {}
    end

    local entries = deployBudget.collectEntries(ai, state, ctx, {
        statPrefix = "pipelineV2MidDeploy"
    })
    if stats then
        stats.pipelineV2MidDeployLegalActions = #entries
    end

    table.sort(entries, function(a, b)
        local av = num(a and a.cheapScore, 0) + deployRoleScore(ctx, a and a.action)
        local bv = num(b and b.cheapScore, 0) + deployRoleScore(ctx, b and b.action)
        if av == bv then
            return tostring(a and a.signature or "") < tostring(b and b.signature or "")
        end
        return av > bv
    end)

    local scanCap = clampLimit(
        options.scanCap or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DEPLOY_SCAN_CAP) or 6,
        0,
        40
    )
    local maxCandidates = clampLimit(
        options.maxCandidates or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DEPLOY_CANDIDATE_CAP) or 3,
        1,
        16
    )
    local candidates = {}
    local seen = {}
    local scanned = 0

    for _, entry in ipairs(entries) do
        if scanned >= scanCap then
            break
        end
        if ctx.shouldStop and ctx.shouldStop() then
            if stats then
                stats.pipelineV2MidDeployStopped = true
            end
            break
        end
        scanned = scanned + 1
        if stats then
            stats.pipelineV2MidDeployEvaluated = num(stats.pipelineV2MidDeployEvaluated, 0) + 1
        end

        local evaluated, rejectReason = evaluateDeploy(ai, state, ctx, midMap, entry)
        if evaluated then
            local prefix = makePrefix(ctx, evaluated)
            local completed = midPositionSecondAction.complete(ai, state, ctx, midMap, prefix, {
                scanCap = ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DEPLOY_SECOND_SCAN_CAP or nil,
                maxCompletions = ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DEPLOY_SECOND_COMPLETION_CAP or nil
            })
            if #completed == 0 then
                if stats then
                    stats.pipelineV2MidDeploySkipCompletion =
                        num(stats.pipelineV2MidDeploySkipCompletion, 0) + 1
                end
                completed = {makeDeploySkipCandidate(ctx, prefix)}
            end
            for _, candidate in ipairs(completed) do
                local signature = tostring(candidate.signature or sequenceSignature(ctx, candidate.actions))
                if not seen[signature] then
                    seen[signature] = true
                    candidate.signature = signature
                    candidate.source = "mid_v2_deploy"
                    candidate.buckets = {"mid_deploy", "mid_position"}
                    candidate.tacticalTags.midDeploy = true
                    candidates[#candidates + 1] = candidate
                end
                if #candidates >= maxCandidates then
                    break
                end
            end
            if #candidates >= maxCandidates then
                break
            end
        else
            bumpReason(stats and stats.pipelineV2MidDeployRejectedReasons, rejectReason)
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
        stats.pipelineV2MidDeployScanned = scanned
        stats.pipelineV2MidDeployCandidates = #candidates
        for index, candidate in ipairs(candidates) do
            if index > 5 then
                break
            end
            stats.pipelineV2MidDeployTop[#stats.pipelineV2MidDeployTop + 1] = compactCandidate(candidate)
        end
    end
    return candidates
end

return M
