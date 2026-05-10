local score = require("ai_tournament.score")
local cacheModule = require("ai_tournament.cache")
local tacticalGate = require("ai_tournament.tactical_gate")
local turnEnumerator = require("ai_tournament.turn_enumerator")
local candidateBuckets = require("ai_tournament.candidate_buckets")
local supplyPlanner = require("ai_tournament.supply_planner")
local reserveModel = require("ai_tournament.reserve_model")
local evaluator = require("ai_tournament.evaluator")
local responseModel = require("ai_tournament.response_model")
local threatModel = require("ai_tournament.threat_model")
local tacticalExtension = require("ai_tournament.tactical_extension")
local earlyPlanner = require("ai_tournament.early_planner")
local debugModule = require("ai_tournament.debug")
local pipelineV2 = require("ai_tournament.pipeline_v2")
local defenseScope = require("ai_tournament.defense_pressure_scope")
local budgetScope = require("ai_tournament.pipeline_v2_budget_scope")

local M = {}

local CONTRACTS = {
    WIN_NOW = "WIN_NOW",
    DEFEND_NOW = "DEFEND_NOW",
    COMBAT_OR_DRAW_RESET = "COMBAT_OR_DRAW_RESET",
    CONVERT_WINNING_POSITION = "CONVERT_WINNING_POSITION",
    BREAK_DRAW_CLOCK = "BREAK_DRAW_CLOCK",
    FORCE_COMMANDANT_PRESSURE = "FORCE_COMMANDANT_PRESSURE",
    ELIMINATE_LOW_HP_UNIT = "ELIMINATE_LOW_HP_UNIT",
    CONVERT_ADVANTAGE = "CONVERT_ADVANTAGE",
    BUILD_POSITION = "BUILD_POSITION",
    TECHNICAL_FALLBACK = "TECHNICAL_FALLBACK"
}

M.CONTRACTS = {}
for name, value in pairs(CONTRACTS) do
    M.CONTRACTS[name] = value
end

local ALLOWED_PASSIVE_PROOFS = {
    wins_now_without_attack = true,
    defends_immediate_lethal = true,
    addresses_commandant_pressure = true,
    forced_defense_over_combat = true,
    forced_defense_safe_combat = true,
    unsafe_combat_rejected_for_commandant_safety = true,
    all_combat_candidates_illegal_after_explicit_sanitize = true,
    all_combat_candidates_allow_immediate_lethal = true,
    all_combat_candidates_unviable_after_generation = true,
    no_legal_faction_attack_available = true,
    no_safe_move_attack_available = true,
    combat_loses_decisive_material_and_no_draw_pressure = true,
    progressive_setup_beats_low_value_combat = true,
    soft_combat_deferred_to_turn_score = true,
    verified_noncombat_forced_win = true,
    defense_race_win = true,
    -- Compatibility aliases kept for old reports.
    combat_all_illegal_after_sanitize = true,
    combat_all_allow_immediate_lethal = true,
    combat_all_decisively_losing_and_no_draw_pressure = true
}

local COMBAT_CLASS_PRIORITY = {
    commandant_kill = 10,
    forced_win_setup = 9,
    immediate_defense_attack = 8,
    safe_unit_kill = 7,
    safe_commandant_pressure = 6,
    safe_high_value_damage = 5,
    official_draw_reset_attack = 4,
    safe_trade = 3,
    low_value_safe_chip = 2,
    unsafe_or_losing_attack = 1
}

local COMBAT_CLASS_FORCE_VALUE = {
    commandant_kill = 10,
    forced_win_setup = 9,
    immediate_defense_attack = 8,
    safe_unit_kill = 7,
    safe_commandant_pressure = 6,
    official_draw_reset_attack = 5,
    safe_trade = 2,
    safe_high_value_damage = 0,
    low_value_safe_chip = 0,
    unsafe_or_losing_attack = 0
}

local isFactionAttack
local earlyAttackCommitmentRejects

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function cfgValue(ctx, key)
    return num(ctx and ctx.cfg and ctx.cfg[key], 0)
end

local function cfgTable(ctx, key)
    local value = ctx and ctx.cfg and ctx.cfg[key]
    if type(value) == "table" then
        return value
    end
    return {}
end

local HARD_STAGE_BUDGET_STATS = {
    immediate_win = {
        extraKey = "hardImmediateWinExtraMs",
        remainingKey = "hardImmediateWinRemainingBeforeMs",
        startKey = "hardImmediateWinStartElapsedMs",
        extendedKey = "hardImmediateWinExtendedHardBudgetMs",
        localWindowKey = "hardImmediateWinLocalWindowMs"
    },
    hard_win = {
        extraKey = "hardWinExtraMs",
        remainingKey = "hardWinRemainingBeforeMs",
        startKey = "hardWinStartElapsedMs",
        extendedKey = "hardWinExtendedHardBudgetMs",
        localWindowKey = "hardWinLocalWindowMs"
    },
    hard_punish = {
        extraKey = "hardPunishExtraMs",
        remainingKey = "hardPunishRemainingBeforeMs",
        startKey = "hardPunishStartElapsedMs",
        extendedKey = "hardPunishExtendedHardBudgetMs",
        localWindowKey = "hardPunishLocalWindowMs"
    },
    hard_defense_lane = {
        extraKey = "hardDefenseExtraMs",
        remainingKey = "hardDefenseRemainingBeforeMs",
        startKey = "hardDefenseStartElapsedMs",
        extendedKey = "hardDefenseExtendedHardBudgetMs",
        localWindowKey = "hardDefenseLocalWindowMs"
    }
}

local function hardStageExtraMs(ctx, specificKey)
    local cfg = ctx and ctx.cfg or {}
    local specific = tonumber(cfg[specificKey])
    if specific ~= nil then
        return math.max(0, specific)
    end
    return math.max(0, num(cfg.HARD_STAGE_EXTRA_MS, 1000))
end

local function pushHardStageBudget(ctx, stageName, specificKey)
    local keys = HARD_STAGE_BUDGET_STATS[stageName] or {}
    return budgetScope.push(ctx, ctx and ctx.stats or nil, {
        extraMs = hardStageExtraMs(ctx, specificKey),
        additive = true,
        extraKey = keys.extraKey,
        remainingKey = keys.remainingKey,
        startKey = keys.startKey,
        extendedKey = keys.extendedKey,
        localWindowKey = keys.localWindowKey
    })
end

local function withHardStageBudget(ctx, stageName, specificKey, fn)
    local budget = pushHardStageBudget(ctx, stageName, specificKey)
    local ok, a, b, c, d, e, f = xpcall(fn, debug.traceback)
    if budget and budget.pop then
        budget.pop()
    end
    if not ok then
        error(a, 0)
    end
    return a, b, c, d, e, f
end

local function isEarlySlowSiegeDeploy(ctx, action)
    if not (ctx
        and ctx.phase
        and ctx.phase.early == true
        and ctx.earlyPlan
        and ctx.earlyPlan.active == true
        and action
        and action.type == "supply_deploy") then
        return false
    end

    if ctx.activeContracts and ctx.activeContracts.defenseActive == true then
        return false
    end

    local unitName = tostring(action.unitName or action.unitType or "")
    local vector = cfgTable(ctx, "SUPPLY_ROLE_VECTOR")[unitName] or {}
    return num(vector.siege, 0) >= cfgValue(ctx, "EARLY_SLOW_SIEGE_MIN_SIEGE")
        and num(vector.mobility, 0) <= cfgValue(ctx, "EARLY_SLOW_SIEGE_MAX_MOBILITY")
end

local function nowMs()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime() * 1000
    end
    return os.clock() * 1000
end

local function clampLimit(value, floor, ceil)
    local v = num(value, floor or 0)
    if floor and v < floor then
        v = floor
    end
    if ceil and v > ceil then
        v = ceil
    end
    return v
end

local function copyArray(values)
    local out = {}
    for i = 1, #(values or {}) do
        out[i] = values[i]
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

local function copyScoreTuple(scoreObj)
    local src = scoreObj or {}
    return {
        tier = src.tier,
        terminal = src.terminal or 0,
        survival = src.survival or 0,
        force = src.force or 0,
        commandant = src.commandant or 0,
        material = src.material or 0,
        supply = src.supply or 0,
        position = src.position or 0,
        risk = src.risk or 0,
        efficiency = src.efficiency or 0,
        total = src.total or 0,
        signature = src.signature,
        breakdown = src.breakdown
    }
end

local function finalizeMeta(meta, ctx, state)
    meta.stats = meta.stats or ctx.stats or {}
    meta.elapsedMs = ctx.elapsedMs and ctx.elapsedMs() or 0
    meta.stateHash = ctx.cache and ctx.cache.stateSignature and ctx.cache.stateSignature(nil, state) or nil
    local reason = tostring(meta.reason or "")
    if not meta.stats.coreExit then
        if reason == "immediate_win" then
            meta.stats.coreExit = "hard_contract"
        elseif meta.contract == CONTRACTS.TECHNICAL_FALLBACK then
            meta.stats.coreExit = meta.stats.timeout and "timeout_no_best" or "technical_fallback"
        elseif meta.selected and meta.selected.candidate then
            meta.stats.coreExit = meta.stats.timeout and "timeout_with_best" or "completed"
        else
            meta.stats.coreExit = meta.stats.timeout and "timeout_no_best" or "no_core_selection"
        end
    end
    if not meta.stats.fallbackSource then
        if meta.stats.coreExit == "budget_guard_with_best"
            or meta.stats.coreExit == "timeout_with_best" then
            meta.stats.fallbackSource = "core_best"
        elseif meta.contract == CONTRACTS.TECHNICAL_FALLBACK then
            meta.stats.fallbackSource = "technical_fallback"
        else
            meta.stats.fallbackSource = "none"
        end
    end
    local stageTotalMs = 0
    for _, value in pairs(meta.stats.stageMs or {}) do
        stageTotalMs = stageTotalMs + num(value, 0)
    end
    local stageMeasuredMs = num(ctx._stageRootMeasuredMs, stageTotalMs)
    meta.stats.stageTotalMs = stageTotalMs
    meta.stats.stageMeasuredMs = stageMeasuredMs
    meta.stats.stageResidualMs = math.max(0, num(meta.elapsedMs, 0) - stageMeasuredMs)

    if ctx.cache then
        meta.stats.cacheHits = ctx.cache.hits or meta.stats.cacheHits or 0
        meta.stats.cacheMisses = ctx.cache.misses or meta.stats.cacheMisses or 0
    end
end

local function actionSignature(ctx, action)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.actionSignature then
        return ctx.turnEnumerator.actionSignature(action)
    end
    return tostring(action and action.type or "unknown")
end

local function addCandidateLane(candidate, laneName)
    candidate.contractLanes = candidate.contractLanes or {}
    candidate.contractLanes[laneName] = true
end

local function candidateHasLane(candidate, laneName)
    return candidate and candidate.contractLanes and candidate.contractLanes[laneName] == true
end

local function candidateHasAnyLane(candidate, laneNames)
    for _, name in ipairs(laneNames or {}) do
        if candidateHasLane(candidate, name) then
            return true
        end
    end
    return false
end

local function candidateHasBucket(candidate, bucket)
    for _, b in ipairs((candidate and candidate.buckets) or {}) do
        if b == bucket then
            return true
        end
    end
    return false
end

local function appendUniqueBucket(candidate, bucket)
    if not bucket then
        return
    end
    candidate.buckets = candidate.buckets or {}
    for _, existing in ipairs(candidate.buckets) do
        if existing == bucket then
            return
        end
    end
    candidate.buckets[#candidate.buckets + 1] = bucket
end

local function getUnitAt(ai, state, row, col)
    if ai and ai.getUnitAtPosition then
        return ai:getUnitAtPosition(state, row, col)
    end
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.row == row and unit.col == col then
            return unit
        end
    end
    return nil
end

local function getActionTargetUnit(ai, state, action)
    if type(action) ~= "table" or type(action.target) ~= "table" then
        return nil
    end

    local target = getUnitAt(ai, state, action.target.row, action.target.col)
    if target then
        return target
    end

    for playerId = 1, 2 do
        local hub = state and state.commandHubs and state.commandHubs[playerId]
        if hub and hub.row == action.target.row and hub.col == action.target.col then
            return {
                name = "Commandant",
                player = playerId,
                row = hub.row,
                col = hub.col,
                currentHp = hub.currentHp,
                startingHp = hub.startingHp
            }
        end
    end

    return nil
end

local function threatPayload(threatResult)
    if not threatResult then
        return nil
    end
    return threatResult.threat or threatResult
end

local function threatProjectedDamage(threatResult)
    local threat = threatPayload(threatResult)
    return num((threatResult and threatResult.projectedDamage) or (threat and threat.projectedDamage), 0)
end

local function threatAttackerCount(threatResult)
    local threat = threatPayload(threatResult)
    return #((threatResult and threatResult.damagingAttackers) or (threat and threat.damagingAttackers) or {})
end

local function threatHasImmediateDanger(threatResult)
    local threat = threatPayload(threatResult)
    return (threatResult and threatResult.immediateDanger == true)
        or (threat and threat.immediateDanger == true)
        or threatProjectedDamage(threatResult) > 0
        or threatAttackerCount(threatResult) > 0
end

local function threatAttackerCells(threatResult)
    local threat = threatPayload(threatResult)
    local cells = {}
    for _, entry in ipairs((threatResult and threatResult.damagingAttackers) or (threat and threat.damagingAttackers) or {}) do
        local unit = entry and entry.unit
        if unit then
            cells[string.format("%d,%d", num(unit.row, -1), num(unit.col, -1))] = true
        end
    end
    return cells
end

local function candidateTargetsThreatUnit(candidate, threatResult)
    if not candidate then
        return false
    end
    local cells = threatAttackerCells(threatResult)
    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "attack" and action.target then
            local key = string.format("%d,%d", num(action.target.row, -1), num(action.target.col, -1))
            if cells[key] then
                return true
            end
        end
    end
    return false
end

local function actionTargetsThreatUnit(action, threatResult)
    if not action or action.type ~= "attack" or not action.target then
        return false
    end
    local cells = threatAttackerCells(threatResult)
    local key = string.format("%d,%d", num(action.target.row, -1), num(action.target.col, -1))
    return cells[key] == true
end

local function candidateThreatAttackDamage(ai, beforeState, candidate, threatResult, playerId, ctx)
    if not (ai and beforeState and candidate and playerId) then
        return 0
    end

    local currentState = beforeState
    local totalDamage = 0
    for _, action in ipairs(candidate.actions or {}) do
        if not action then
            break
        end

        if actionTargetsThreatUnit(action, threatResult) and isFactionAttack(ctx, currentState, action, playerId) then
            local attacker = getUnitAt(ai, currentState, action.unit and action.unit.row, action.unit and action.unit.col)
            local target = getActionTargetUnit(ai, currentState, action)
            if attacker and target and ai.calculateDamage then
                totalDamage = totalDamage + math.max(0, num(ai:calculateDamage(attacker, target), 0))
            end
        end

        if action.type and action.type ~= "skip" and currentState then
            currentState = (ctx and ctx.cache and ctx.cache.simulate)
                and ctx.cache.simulate(ai, currentState, {action}, playerId, ctx)
                or (ai.simulateActionSequenceForPlayer and ai:simulateActionSequenceForPlayer(currentState, {action}, playerId, {}))
        end
    end

    return totalDamage
end

local function candidateSpendsAttackOffThreat(ai, beforeState, candidate, threatResult, playerId, ctx)
    if not (ai and beforeState and candidate and playerId) then
        return false
    end

    local currentState = beforeState
    for _, action in ipairs(candidate.actions or {}) do
        if not action then
            break
        end

        if action.type == "attack" then
            local target = action.target
                and getUnitAt(ai, currentState, action.target.row, action.target.col)
                or nil
            local enemyFactionTarget = target
                and num(target.player, 0) ~= 0
                and num(target.player, 0) ~= num(playerId, 0)
                and not (ai.isObstacleUnit and ai:isObstacleUnit(target))
            local factionAttack = isFactionAttack(ctx, currentState, action, playerId) == true
                or enemyFactionTarget == true
            if factionAttack and not actionTargetsThreatUnit(action, threatResult) then
                return true
            end
        end

        if action.type and action.type ~= "skip" and currentState then
            currentState = (ctx and ctx.cache and ctx.cache.simulate)
                and ctx.cache.simulate(ai, currentState, {action}, playerId, ctx)
                or (ai.simulateActionSequenceForPlayer and ai:simulateActionSequenceForPlayer(currentState, {action}, playerId, {}))
        end
    end

    return false
end

local function threatBlockCells(threatResult)
    local threat = threatPayload(threatResult)
    local cells = {}
    for _, cell in ipairs((threatResult and threatResult.blockCells) or (threat and threat.blockCells) or {}) do
        cells[string.format("%d,%d", num(cell.row, -1), num(cell.col, -1))] = true
    end
    return cells
end

local function actionTouchesThreatBlock(action, threatResult)
    if not action or not action.target then
        return false
    end
    if action.type ~= "move" and action.type ~= "supply_deploy" then
        return false
    end
    local cells = threatBlockCells(threatResult)
    local key = string.format("%d,%d", num(action.target.row, -1), num(action.target.col, -1))
    return cells[key] == true
end

local function candidateTouchesThreatBlock(candidate, threatResult)
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if actionTouchesThreatBlock(action, threatResult) then
            return true
        end
    end
    return false
end

local function candidateHasDefensePressureTag(candidate)
    local tags = candidate and candidate.tacticalTags or {}
    return tags.targetsCommandantThreat == true
        or tags.addressesCommandantPressure == true
        or tags.clearsCommandantPressure == true
        or tags.blocksThreatLine == true
        or tags.defensivePressureMove == true
        or tags.defensiveThreatRemovalSetup == true
        or tags.defensiveBlockerEvacuation == true
end

local function findThreatUnitAt(ai, state, threatUnit)
    if not (state and threatUnit) then
        return nil
    end
    local row = num(threatUnit.row, nil)
    local col = num(threatUnit.col, nil)
    if not (row and col) then
        return nil
    end
    local current = getUnitAt(ai, state, row, col)
    if current and num(current.player, 0) == num(threatUnit.player, 0) and current.name == threatUnit.name then
        return current
    end
    return nil
end

local function candidateMovesCurrentThreatResponder(ai, beforeState, candidate, threatResult, playerId, ctx)
    if not (ai and beforeState and candidate and playerId) then
        return false
    end

    local threat = threatPayload(threatResult)
    local entries = (threatResult and threatResult.damagingAttackers)
        or (threat and threat.damagingAttackers)
        or {}
    if #entries == 0 then
        return false
    end

    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "move" and action.unit then
            local unit = getUnitAt(ai, beforeState, action.unit.row, action.unit.col)
            if unit and num(unit.player, 0) == num(playerId, 0) then
                for _, entry in ipairs(entries) do
                    local threatUnit = findThreatUnitAt(ai, beforeState, entry and entry.unit)
                    if threatUnit and num(threatUnit.currentHp or threatUnit.startingHp, 0) > 0 then
                        local damage = num(ai.calculateDamage and ai:calculateDamage(unit, threatUnit), 0)
                        local eta = nil
                        if ai.getUnitThreatTiming then
                            eta = ai:getUnitThreatTiming(beforeState, unit, threatUnit, 1, {
                                requirePositiveDamage = true,
                                considerCurrentActionState = true,
                                allowMoveOnFirstTurn = true,
                                maxFrontierNodes = 18
                            })
                        end
                        if damage > 0 or (eta and eta <= 1) then
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

local function deployedUnitForAction(ai, state, action, playerId)
    if not (state and action and action.type == "supply_deploy" and action.target) then
        return nil
    end
    local unit = getUnitAt(ai, state, action.target.row, action.target.col)
    if unit
        and num(unit.player, 0) == num(playerId, 0)
        and tostring(unit.name or "") == tostring(action.unitName or action.unitType or "") then
        return unit
    end
    return nil
end

local function unitCanAttackTarget(ai, state, unit, target)
    if not (ai and state and unit and target and ai.getValidAttackCells) then
        return false
    end
    local cells = ai:getValidAttackCells(state, unit.row, unit.col) or {}
    for _, cell in ipairs(cells) do
        if num(cell and cell.row, -1) == num(target.row, -2)
            and num(cell and cell.col, -1) == num(target.col, -2) then
            return true
        end
    end
    return false
end

local function isHubAdjacentCell(state, playerId, row, col)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    return hub and math.abs(num(row, 0) - num(hub.row, 0)) + math.abs(num(col, 0) - num(hub.col, 0)) == 1
end

local function unitThreatDamageNow(ai, state, unit, threatUnit)
    if not (ai and state and unit and threatUnit and ai.calculateDamage) then
        return 0
    end
    if not unitCanAttackTarget(ai, state, unit, threatUnit) then
        return 0
    end
    return math.max(0, num(ai:calculateDamage(unit, threatUnit), 0))
end

local function candidateEvacuatesDefenseBlocker(ai, beforeState, candidate, threatResult, playerId)
    if not (ai and beforeState and candidate and threatResult and playerId) then
        return false
    end

    local threatEntries = (threatResult and threatResult.damagingAttackers)
        or (threatPayload(threatResult) and threatPayload(threatResult).damagingAttackers)
        or {}
    if #threatEntries == 0 then
        return false
    end

    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "move" and action.unit and action.target then
            local blocker = getUnitAt(ai, beforeState, action.unit.row, action.unit.col)
            if blocker
                and num(blocker.player, 0) == num(playerId, 0)
                and not (ai.isHubUnit and ai:isHubUnit(blocker))
                and not (ai.isObstacleUnit and ai:isObstacleUnit(blocker)) then
                for _, entry in ipairs(threatEntries) do
                    local threatUnit = findThreatUnitAt(ai, beforeState, entry and entry.unit)
                    if threatUnit then
                        local adjacentToThreat = math.abs(num(blocker.row, 0) - num(threatUnit.row, 0))
                            + math.abs(num(blocker.col, 0) - num(threatUnit.col, 0)) == 1
                        local hubAdjacent = isHubAdjacentCell(beforeState, playerId, blocker.row, blocker.col)
                        if (adjacentToThreat or hubAdjacent) and unitThreatDamageNow(ai, beforeState, blocker, threatUnit) <= 0 then
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

local function candidateMovesNearOwnHub(candidate, state, playerId)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if not (candidate and hub) then
        return false
    end

    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "move" and action.unit then
            local originDistance = math.abs(num(action.unit.row, 0) - num(hub.row, 0))
                + math.abs(num(action.unit.col, 0) - num(hub.col, 0))
            local target = action.target or {}
            local targetDistance = math.abs(num(target.row, 0) - num(hub.row, 0))
                + math.abs(num(target.col, 0) - num(hub.col, 0))
            if originDistance <= 3 or targetDistance <= 3 then
                return true
            end
        end
    end

    return false
end

local function candidateOpensCommandantPressure(ai, beforeState, afterOur, candidate, ctx)
    if not (ai and beforeState and afterOur and candidate and ctx and ctx.aiPlayer and ctx.enemyPlayer) then
        return false
    end
    if candidate.tacticalTags and candidate.tacticalTags.winsNow == true then
        return false
    end
    if not candidateMovesNearOwnHub(candidate, beforeState, ctx.aiPlayer) then
        return false
    end
    if not (ctx.cache and ctx.cache.threat) then
        return false
    end

    local beforeThreat = ctx.cache.threat(ai, beforeState, ctx.aiPlayer, ctx.enemyPlayer, ctx)
    local afterThreat = ctx.cache.threat(ai, afterOur, ctx.aiPlayer, ctx.enemyPlayer, ctx)
    local beforeDanger = threatHasImmediateDanger(beforeThreat)
    local afterDanger = threatHasImmediateDanger(afterThreat)
    if not afterDanger then
        return false
    end
    if beforeDanger and threatProjectedDamage(afterThreat) <= threatProjectedDamage(beforeThreat) then
        return false
    end

    candidate.tacticalTags = candidate.tacticalTags or {}
    candidate.tacticalTags.opensCommandantPressure = true
    candidate.tacticalTags.openedCommandantPressureDamage = threatProjectedDamage(afterThreat)
    return true
end

local function itemOpensCommandantPressure(ai, state, ctx, item)
    local candidate = item and item.candidate or nil
    if not candidate then
        return false
    end
    local tags = candidate.tacticalTags or {}
    if tags.opensCommandantPressure == true then
        return true
    end
    local afterOur = item.afterOur
    if not afterOur and candidate.actions then
        afterOur = (ctx and ctx.cache and ctx.cache.simulate)
            and ctx.cache.simulate(ai, state, candidate.actions, ctx.aiPlayer, ctx)
            or (ai and ai.simulateActionSequenceForPlayer
                and ai:simulateActionSequenceForPlayer(state, candidate.actions, ctx and ctx.aiPlayer, {}))
    end
    return candidateOpensCommandantPressure(ai, state, afterOur, candidate, ctx)
end

local function copyStateForSetup(ai, state)
    if ai and ai.deepCopyState then
        local ok, copied = pcall(ai.deepCopyState, ai, state)
        if ok and copied then
            return copied
        end
    end
    return nil
end

local function unitCanThreatenTargetNextTurn(ai, state, unit, target)
    if unitCanAttackTarget(ai, state, unit, target) then
        return true, unit, "direct_attack"
    end
    if not (ai and state and unit and target and ai.getValidMoveCells) then
        return false, nil, nil
    end

    local moveCells = ai:getValidMoveCells(state, unit.row, unit.col) or {}
    for _, cell in ipairs(moveCells) do
        local simulated = copyStateForSetup(ai, state)
        if simulated then
            local movedUnit = getUnitAt(ai, simulated, unit.row, unit.col)
            local movedTarget = getUnitAt(ai, simulated, target.row, target.col)
            if movedUnit and movedTarget then
                movedUnit.row = cell.row
                movedUnit.col = cell.col
                movedUnit.hasMoved = false
                movedUnit.hasActed = false
                movedUnit.actionsUsed = 0
                if unitCanAttackTarget(ai, simulated, movedUnit, movedTarget) then
                    return true, movedUnit, "move_attack"
                end
            end
        end
    end

    return false, nil, nil
end

local function finiteNumberOrNil(value)
    local n = tonumber(value)
    if n == nil then
        return nil
    end
    if n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    return n
end

local function actionCountPerTurn(ai)
    local turnCfg = (((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).TURN or {}
    return clampLimit(turnCfg.ACTIONS_PER_TURN or 2, 1, 3)
end

local function buildHubUnitForPlayer(state, playerId)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if not hub then
        return nil
    end
    return {
        name = "Commandant",
        player = playerId,
        row = hub.row,
        col = hub.col,
        currentHp = hub.currentHp,
        startingHp = hub.startingHp
    }
end

local function commandantAutoDamageAgainstThreat(ai, state, playerId, threatUnit)
    local commandant = buildHubUnitForPlayer(state, playerId)
    if not (ai and state and commandant and threatUnit and ai.calculateDamage) then
        return 0
    end
    if num(threatUnit.player, 0) == 0 or num(threatUnit.player, 0) == num(playerId, 0) then
        return 0
    end
    if not unitCanAttackTarget(ai, state, commandant, threatUnit) then
        return 0
    end
    return math.max(0, num(ai:calculateDamage(commandant, threatUnit), 0))
end

local function isRaceEligibleUnit(ai, unit, playerId)
    if not unit or num(unit.player, 0) ~= num(playerId, 0) then
        return false
    end
    if ai and ai.isHubUnit and ai:isHubUnit(unit) then
        return false
    end
    if ai and ai.isObstacleUnit and ai:isObstacleUnit(unit) then
        return false
    end
    return num(unit.currentHp or unit.startingHp, 0) > 0
end

local function positionDistance(a, b)
    if not a or not b then
        return 999
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function prepareTurnForPlayer(ai, state, playerId)
    if ai and ai.prepareStateForPlayerTurn then
        return ai:prepareStateForPlayerTurn(state, playerId, {
            resetDeployment = true,
            resetActionCount = true,
            resetFirstActionRangedAttack = true
        })
    end
    return state
end

local function estimateThreatTurnsToDeath(state, playerId, threatResult)
    local threat = threatPayload(threatResult)
    if not threatHasImmediateDanger(threatResult) then
        return nil
    end
    if (threatResult and threatResult.immediateLethal == true) or (threat and threat.immediateLethal == true) then
        return 1
    end

    local hub = state and state.commandHubs and state.commandHubs[playerId]
    local hubHp = num(hub and (hub.currentHp or hub.startingHp), 0)
    local projectedDamage = threatProjectedDamage(threatResult)
    if hubHp <= 0 then
        return 0
    end
    if projectedDamage <= 0 then
        return nil
    end
    return math.max(1, math.ceil(hubHp / projectedDamage))
end

local function estimateOffenseTimeToWin(ai, state, playerId, enemyPlayer, ctx, opts)
    if not (ai and state and playerId and enemyPlayer and ai.getUnitThreatTiming and ai.calculateDamage) then
        return nil, nil
    end

    local options = opts or {}
    local horizon = clampLimit(options.horizonTurns or (ctx and ctx.cfg and ctx.cfg.DEFENSE_RACE_TTW_HORIZON_TURNS) or 4, 1, 6)
    local prepared = prepareTurnForPlayer(ai, state, playerId)
    local enemyHub = buildHubUnitForPlayer(prepared, enemyPlayer)
    local enemyHubHp = num(enemyHub and (enemyHub.currentHp or enemyHub.startingHp), 0)
    if enemyHubHp <= 0 then
        return 0, {
            horizon = horizon,
            aggregatedDamage = 0
        }
    end

    local timingEntries = {}
    for _, unit in ipairs((prepared and prepared.units) or {}) do
        if isRaceEligibleUnit(ai, unit, playerId) then
            local timing, mode = ai:getUnitThreatTiming(prepared, unit, enemyHub, horizon, {
                requirePositiveDamage = true,
                considerCurrentActionState = true,
                allowMoveOnFirstTurn = true,
                maxFrontierNodes = clampLimit((ctx and ctx.cfg and ctx.cfg.DEFENSE_RACE_TTW_MAX_FRONTIER) or 18, 8, 36)
            })
            timing = finiteNumberOrNil(timing)
            if timing and timing >= 1 then
                local damage = num(ai:calculateDamage(unit, enemyHub), 0)
                if damage > 0 then
                    timingEntries[#timingEntries + 1] = {
                        turn = timing,
                        damage = damage,
                        unitName = unit.name,
                        mode = mode
                    }
                end
            end
        end
    end

    if #timingEntries == 0 then
        return nil, {
            horizon = horizon,
            aggregatedDamage = 0
        }
    end

    local attacksPerTurn = actionCountPerTurn(ai)
    for turn = 1, horizon do
        local available = {}
        for _, entry in ipairs(timingEntries) do
            if num(entry.turn, 99) <= turn then
                available[#available + 1] = entry
            end
        end

        table.sort(available, function(a, b)
            if num(a.damage, 0) ~= num(b.damage, 0) then
                return num(a.damage, 0) > num(b.damage, 0)
            end
            return tostring(a.unitName or "") < tostring(b.unitName or "")
        end)

        local attackBudget = turn * attacksPerTurn
        local aggregatedDamage = 0
        for idx = 1, math.min(attackBudget, #available) do
            aggregatedDamage = aggregatedDamage + num(available[idx].damage, 0)
        end
        if aggregatedDamage >= enemyHubHp then
            return turn, {
                horizon = horizon,
                entries = timingEntries,
                aggregatedDamage = aggregatedDamage
            }
        end
    end

    return nil, {
        horizon = horizon,
        entries = timingEntries
    }
end

local function estimateCandidateWinRaceTTW(ai, state, item, ctx)
    if not (ai and state and item and item.candidate and item.candidate.hasFactionAttack == true and ctx) then
        return nil
    end
    if num(item and item.finalScore and item.finalScore.tier, 0) >= num(ctx.score and ctx.score.TIER and ctx.score.TIER.WIN_NOW, 0) then
        return 1
    end

    local afterOur = item.afterOur
    if not afterOur and ctx.cache and ctx.cache.simulate then
        afterOur = ctx.cache.simulate(ai, state, item.candidate.actions, ctx.aiPlayer, ctx)
    end
    if not afterOur then
        return nil
    end

    local hubAfter = afterOur and afterOur.commandHubs and afterOur.commandHubs[ctx.enemyPlayer]
    if num(hubAfter and (hubAfter.currentHp or hubAfter.startingHp), 0) <= 0 then
        return 1
    end

    local nextTurnsToWin = select(1, estimateOffenseTimeToWin(ai, afterOur, ctx.aiPlayer, ctx.enemyPlayer, ctx, {
        horizonTurns = clampLimit((ctx and ctx.cfg and ctx.cfg.DEFENSE_RACE_TTW_HORIZON_TURNS) or 4, 1, 6)
    }))
    if not nextTurnsToWin then
        return nil
    end

    return 1 + nextTurnsToWin
end

local function leavesImmediateNonHubAllyLethal(ai, state, ctx)
    if not (ai and state and ctx and ctx.aiPlayer and ctx.enemyPlayer and ai.collectLegalActions) then
        return false
    end

    local enemyTurn = state
    if ai.prepareStateForPlayerTurn then
        enemyTurn = ai:prepareStateForPlayerTurn(state, ctx.enemyPlayer, {
            resetDeployment = true,
            resetActionCount = true,
            resetFirstActionRangedAttack = true
        })
    end

    local entries = ai:collectLegalActions(enemyTurn, {
        aiPlayer = ctx.enemyPlayer,
        includeMove = false,
        includeAttack = true,
        includeRepair = false,
        includeDeploy = false
    }) or {}

    for _, entry in ipairs(entries) do
        local action = entry and entry.action or nil
        if action and action.type == "attack" then
            local attacker = getUnitAt(ai, enemyTurn, action.unit and action.unit.row, action.unit and action.unit.col)
            local target = getActionTargetUnit(ai, enemyTurn, action)
            if target
                and num(target.player, 0) == num(ctx.aiPlayer, 0)
                and not (ai.isHubUnit and ai:isHubUnit(target))
                and not (ai.isObstacleUnit and ai:isObstacleUnit(target)) then
                local damage = 0
                if ai.calculateDamage then
                    damage = num(ai:calculateDamage(attacker, target), 0)
                end
                local hp = num(target.currentHp or target.startingHp, 0)
                if hp > 0 and damage >= hp then
                    return true
                end
            end
        end
    end

    return false
end

local function unitIdentityKey(unit)
    if not unit then
        return "invalid"
    end
    return string.format(
        "%s:%d@%d,%d",
        tostring(unit.name or "?"),
        num(unit.player, -1),
        num(unit.row, -1),
        num(unit.col, -1)
    )
end

local function buildDefenseSetupSourceByUnit(ai, afterOur, candidate, playerId, ctx)
    local byUnit = {}
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action and action.type == "supply_deploy" and action.target then
            local key = string.format(
                "%s:%d@%d,%d",
                tostring(action.unitName or action.unitType or "?"),
                num(playerId, -1),
                num(action.target.row, -1),
                num(action.target.col, -1)
            )
            byUnit[key] = {
                source = "deploy",
                signature = actionSignature(ctx, action),
                row = action.target.row,
                col = action.target.col,
                action = action
            }
        elseif action and action.type == "move" and action.target then
            local moved = getUnitAt(ai, afterOur, action.target.row, action.target.col)
            if moved and num(moved.player, 0) == num(playerId, 0) then
                byUnit[unitIdentityKey(moved)] = {
                    source = "move",
                    signature = actionSignature(ctx, action),
                    row = action.target.row,
                    col = action.target.col
                }
            end
        end
    end
    return byUnit
end

local function projectedEnemyDamageOnCell(ai, state, enemyPlayer, row, col)
    if not (ai and state and enemyPlayer and row and col and ai.getValidAttackCells and ai.calculateDamage) then
        return 0
    end
    local enemyTurn = prepareTurnForPlayer(ai, state, enemyPlayer)
    local target = getUnitAt(ai, enemyTurn, row, col)
    if not target then
        return 0
    end

    local total = 0
    for _, enemy in ipairs((enemyTurn and enemyTurn.units) or {}) do
        if enemy
            and num(enemy.player, 0) == num(enemyPlayer, 0)
            and not (ai.isHubUnit and ai:isHubUnit(enemy))
            and not (ai.isObstacleUnit and ai:isObstacleUnit(enemy)) then
            local attackCells = ai:getValidAttackCells(enemyTurn, enemy.row, enemy.col) or {}
            for _, cell in ipairs(attackCells) do
                if num(cell and cell.row, -1) == num(row, -2) and num(cell and cell.col, -1) == num(col, -2) then
                    total = total + num(ai:calculateDamage(enemy, target), 0)
                    break
                end
            end
        end
    end
    return total
end

local function unitThreatEtaAgainstTarget(ai, state, unit, target, maxEta, ctx)
    if not (ai and state and unit and target) then
        return nil, nil
    end

    if ai.getUnitThreatTiming then
        local eta, mode = ai:getUnitThreatTiming(state, unit, target, maxEta, {
            requirePositiveDamage = true,
            considerCurrentActionState = true,
            allowMoveOnFirstTurn = true,
            maxFrontierNodes = clampLimit((ctx and ctx.cfg and ctx.cfg.DEFENSE_RACE_MAX_FRONTIER) or 16, 8, 32)
        })
        eta = finiteNumberOrNil(eta)
        if eta and eta >= 1 then
            return eta, mode
        end
    end

    if maxEta >= 1 then
        local canThreaten, _, route = unitCanThreatenTargetNextTurn(ai, state, unit, target)
        if canThreaten then
            return 1, route
        end
    end

    return nil, nil
end

local function sourceCost(source)
    if source == "deploy" then
        return 2
    end
    if source == "move" then
        return 1
    end
    return 0
end

local function setupBetter(a, b)
    if not a then
        return false
    end
    if not b then
        return true
    end
    if num(a.eta, 99) ~= num(b.eta, 99) then
        return num(a.eta, 99) < num(b.eta, 99)
    end
    if num(a.damage, 0) ~= num(b.damage, 0) then
        return num(a.damage, 0) > num(b.damage, 0)
    end
    if (a.lethal == true) ~= (b.lethal == true) then
        return a.lethal == true
    end
    if (a.survives == true) ~= (b.survives == true) then
        return a.survives == true
    end
    if num(a.opportunityCost, 0) ~= num(b.opportunityCost, 0) then
        return num(a.opportunityCost, 0) < num(b.opportunityCost, 0)
    end
    if num(a.deployScore, 0) ~= num(b.deployScore, 0) then
        return num(a.deployScore, 0) > num(b.deployScore, 0)
    end
    local aSig = tostring(a.unitName or "?") .. ":" .. tostring(a.targetName or "?")
    local bSig = tostring(b.unitName or "?") .. ":" .. tostring(b.targetName or "?")
    return aSig < bSig
end

local function setupStrictlyBetterForRejection(a, b)
    if not a or not b then
        return false
    end
    if num(a.eta, 99) ~= num(b.eta, 99) then
        return num(a.eta, 99) < num(b.eta, 99)
    end
    if num(a.damage, 0) ~= num(b.damage, 0) then
        return num(a.damage, 0) > num(b.damage, 0)
    end
    if (a.lethal == true) ~= (b.lethal == true) then
        return a.lethal == true
    end
    if (a.survives == true) ~= (b.survives == true) then
        return a.survives == true
    end
    if num(a.opportunityCost, 0) ~= num(b.opportunityCost, 0) then
        return num(a.opportunityCost, 0) < num(b.opportunityCost, 0)
    end
    return false
end

local function scoreDeploySetupAction(ai, state, deployAction, playerId, ctx)
    if not (ai and state and deployAction and deployAction.type == "supply_deploy" and ctx and ctx.supplyPlanner) then
        return 0
    end
    if not ctx.supplyPlanner.scoreDeployCheap then
        return 0
    end

    local demand = nil
    if ctx.supplyPlanner.buildRoleDemand then
        if ctx._defenseDeployDemand == nil then
            ctx._defenseDeployDemand = ctx.supplyPlanner.buildRoleDemand(ai, state, playerId, ctx)
        end
        demand = ctx._defenseDeployDemand
    end

    local ok, score = pcall(ctx.supplyPlanner.scoreDeployCheap, ai, state, deployAction, playerId, ctx, demand)
    if ok then
        return num(score, 0)
    end
    return 0
end

local function bestCurrentDeployThreatSetup(ai, state, contracts, ctx)
    if not (ai and state and contracts and contracts.defenseKind == "pressure" and ctx) then
        return nil
    end
    if state.hasDeployedThisTurn == true then
        return nil
    end

    local threat = threatPayload(contracts.defenseThreat)
    local threatEntries = (contracts.defenseThreat and contracts.defenseThreat.damagingAttackers)
        or (threat and threat.damagingAttackers)
        or {}
    if #threatEntries == 0 then
        return nil
    end

    local deployments = {}
    if ai.getPossibleSupplyDeploymentsForPlayer then
        deployments = ai:getPossibleSupplyDeploymentsForPlayer(state, ctx.aiPlayer, true, {
            scoreDeployments = false
        }) or {}
    elseif ai.getPossibleSupplyDeployments then
        deployments = ai:getPossibleSupplyDeployments(state, true) or {}
    end
    if #deployments == 0 then
        return nil
    end

    local maxEta = clampLimit((ctx.cfg and ctx.cfg.DEFENSE_RACE_MAX_SETUP_ETA) or 4, 1, 6)
    local best = nil
    for _, deployment in ipairs(deployments) do
        if deployment and deployment.target then
            local afterDeploy = nil
            if ai.applySupplyDeploymentForPlayer then
                afterDeploy = ai:applySupplyDeploymentForPlayer(state, deployment, ctx.aiPlayer, {
                    scoreDeployments = false
                })
            elseif ai.applySupplyDeployment then
                afterDeploy = ai:applySupplyDeployment(state, deployment)
            end

            local nextOwnTurn = afterDeploy and prepareTurnForPlayer(ai, afterDeploy, ctx.aiPlayer) or nil
            local deployed = nextOwnTurn and getUnitAt(ai, nextOwnTurn, deployment.target.row, deployment.target.col) or nil
            if isRaceEligibleUnit(ai, deployed, ctx.aiPlayer) then
                for _, threatEntry in ipairs(threatEntries) do
                    local threatUnit = findThreatUnitAt(ai, nextOwnTurn, threatEntry and threatEntry.unit)
                    if threatUnit and num(threatUnit.currentHp or threatUnit.startingHp, 0) > 0 then
                        local eta, route = unitThreatEtaAgainstTarget(ai, nextOwnTurn, deployed, threatUnit, maxEta, ctx)
                        if eta and eta >= 1 and eta <= maxEta then
                        local damage = num(ai.calculateDamage and ai:calculateDamage(deployed, threatUnit), 0)
                            if damage > 0 then
                                local deployScore = scoreDeploySetupAction(ai, state, deployment, ctx.aiPlayer, ctx)
                                local setup = {
                                    action = copyMap(deployment),
                                    eta = eta,
                                    damage = damage,
                                    targetHp = num(threatUnit.currentHp or threatUnit.startingHp, 0),
                                    lethal = damage >= num(threatUnit.currentHp or threatUnit.startingHp, 0),
                                    route = route,
                                    source = "deploy",
                                    sourceSignature = actionSignature(ctx, deployment),
                                    sourceRow = deployment.target.row,
                                    sourceCol = deployment.target.col,
                                    deployScore = deployScore,
                                    opportunityCost = sourceCost("deploy"),
                                    survives = true,
                                    unitName = tostring(deployed.name or deployment.unitName or "?"),
                                    targetName = tostring(threatUnit.name or "?"),
                                    targetRow = threatUnit.row,
                                    targetCol = threatUnit.col
                                }
                                if setupBetter(setup, best) then
                                    best = setup
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return best
end

local function bestCurrentDeployThreatReduction(ai, state, contracts, ctx)
    if not (ai and state and contracts and contracts.defenseKind == "pressure" and ctx) then
        return nil
    end
    if state.hasDeployedThisTurn == true then
        return nil
    end
    if not (ctx.cache and ctx.cache.threat) then
        return nil
    end

    local beforeThreat = ctx.cache.threat(ai, state, ctx.aiPlayer, ctx.enemyPlayer, ctx)
    if not threatHasImmediateDanger(beforeThreat) then
        return nil
    end

    local deployments = {}
    if ai.getPossibleSupplyDeploymentsForPlayer then
        deployments = ai:getPossibleSupplyDeploymentsForPlayer(state, ctx.aiPlayer, true, {
            scoreDeployments = false
        }) or {}
    elseif ai.getPossibleSupplyDeployments then
        deployments = ai:getPossibleSupplyDeployments(state, true) or {}
    end

    local beforeProjected = threatProjectedDamage(beforeThreat)
    local beforeCount = #((beforeThreat and beforeThreat.damagingAttackers) or {})
    local best = nil

    for _, deployment in ipairs(deployments) do
        if deployment and deployment.target then
            local afterDeploy = nil
            if ai.applySupplyDeploymentForPlayer then
                afterDeploy = ai:applySupplyDeploymentForPlayer(state, deployment, ctx.aiPlayer, {
                    scoreDeployments = false
                })
            elseif ai.applySupplyDeployment then
                afterDeploy = ai:applySupplyDeployment(state, deployment)
            end

            local afterThreat = afterDeploy and ctx.cache.threat(ai, afterDeploy, ctx.aiPlayer, ctx.enemyPlayer, ctx) or nil
            if afterThreat then
                local afterProjected = threatProjectedDamage(afterThreat)
                local afterCount = #((afterThreat and afterThreat.damagingAttackers) or {})
                local projectedDelta = beforeProjected - afterProjected
                local attackerDelta = beforeCount - afterCount
                if projectedDelta > 0 or attackerDelta > 0 or afterThreat.immediateDanger ~= true then
                    local score = (projectedDelta * 1000) + (attackerDelta * 600)
                    if beforeThreat.immediateDanger == true and afterThreat.immediateDanger ~= true then
                        score = score + 5000
                    end
                    if beforeThreat.immediateLethal == true and afterThreat.immediateLethal ~= true then
                        score = score + 8000
                    end
                    score = score + num(deployment.cheapScore, 0)

                    local current = {
                        action = deployment,
                        score = score,
                        projectedDelta = projectedDelta,
                        attackerDelta = attackerDelta,
                        beforeProjected = beforeProjected,
                        afterProjected = afterProjected,
                        beforeCount = beforeCount,
                        afterCount = afterCount,
                        signature = actionSignature(ctx, deployment)
                    }
                    if not best
                        or current.score > best.score
                        or (
                            current.score == best.score
                            and tostring(current.signature or "") < tostring(best.signature or "")
                        ) then
                        best = current
                    end
                end
            end
        end
    end

    return best
end

local function bestCandidateDeployThreatSetup(ai, afterOur, candidate, contracts, ctx)
    if not (ai and afterOur and candidate and contracts and contracts.defenseKind == "pressure" and ctx) then
        return nil
    end

    local threat = threatPayload(contracts.defenseThreat)
    local threatEntries = (contracts.defenseThreat and contracts.defenseThreat.damagingAttackers)
        or (threat and threat.damagingAttackers)
        or {}
    if #threatEntries == 0 then
        return nil
    end

    local nextOwnTurn = prepareTurnForPlayer(ai, afterOur, ctx.aiPlayer)
    local maxEta = clampLimit((ctx.cfg and ctx.cfg.DEFENSE_RACE_MAX_SETUP_ETA) or 4, 1, 6)
    local best = nil

    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "supply_deploy" and action.target then
            local deployed = getUnitAt(ai, nextOwnTurn, action.target.row, action.target.col)
            if isRaceEligibleUnit(ai, deployed, ctx.aiPlayer) then
                for _, threatEntry in ipairs(threatEntries) do
                    local threatUnit = findThreatUnitAt(ai, nextOwnTurn, threatEntry and threatEntry.unit)
                    if threatUnit and num(threatUnit.currentHp or threatUnit.startingHp, 0) > 0 then
                        local eta, route = unitThreatEtaAgainstTarget(ai, nextOwnTurn, deployed, threatUnit, maxEta, ctx)
                        if eta and eta >= 1 and eta <= maxEta then
                            local unitDamage = num(ai.calculateDamage and ai:calculateDamage(deployed, threatUnit), 0)
                            if unitDamage > 0 then
                                local commandantAutoDamage = commandantAutoDamageAgainstThreat(
                                    ai,
                                    nextOwnTurn,
                                    ctx.aiPlayer,
                                    threatUnit
                                )
                                local deployScore = scoreDeploySetupAction(ai, ctx.currentState, action, ctx.aiPlayer, ctx)
                                local targetHp = num(threatUnit.currentHp or threatUnit.startingHp, 0)
                                local ownHp = num(deployed.currentHp or deployed.startingHp, 0)
                                local incomingDamage = projectedEnemyDamageOnCell(
                                    ai,
                                    nextOwnTurn,
                                    ctx.enemyPlayer,
                                    deployed.row,
                                    deployed.col
                                )
                                local damage = unitDamage + commandantAutoDamage
                                local setup = {
                                    eta = eta,
                                    damage = damage,
                                    unitDamage = unitDamage,
                                    commandantAutoDamage = commandantAutoDamage,
                                    targetHp = targetHp,
                                    lethal = damage >= targetHp,
                                    route = route,
                                    source = "deploy",
                                    sourceSignature = actionSignature(ctx, action),
                                    sourceRow = action.target.row,
                                    sourceCol = action.target.col,
                                    deployScore = deployScore,
                                    opportunityCost = sourceCost("deploy"),
                                    survives = ownHp - num(incomingDamage, 0) > 0,
                                    survivalMargin = ownHp - num(incomingDamage, 0),
                                    unitName = tostring(deployed.name or action.unitName or "?"),
                                    targetName = tostring(threatUnit.name or "?"),
                                    targetRow = threatUnit.row,
                                    targetCol = threatUnit.col
                                }
                                if setupBetter(setup, best) then
                                    best = setup
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return best
end

local function defenseThreatEntries(contracts)
    local defenseThreat = contracts and contracts.defenseThreat
    local threat = threatPayload(defenseThreat)
    return (defenseThreat and defenseThreat.damagingAttackers)
        or (threat and threat.damagingAttackers)
        or {}
end

local function simulateCandidateWithoutDeploys(ai, state, candidate, playerId, ctx)
    if not (ai and state and candidate and playerId) then
        return nil, false
    end

    local currentState = state
    local skippedDeploy = false
    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "supply_deploy" then
            skippedDeploy = true
        elseif action and action.type and action.type ~= "skip" then
            currentState = (ctx and ctx.cache and ctx.cache.simulate)
                and ctx.cache.simulate(ai, currentState, {action}, playerId, ctx)
                or (ai.simulateActionSequenceForPlayer and ai:simulateActionSequenceForPlayer(currentState, {action}, playerId, {}))
            if not currentState then
                return nil, skippedDeploy
            end
        end
    end

    return currentState, skippedDeploy
end

local function boardOnlyThreatRemovalPlan(ai, state, candidate, contracts, ctx, opts)
    if not (ai and state and candidate and contracts and contracts.defenseKind == "pressure" and ctx) then
        return nil
    end

    local afterNonDeploy, skippedDeploy = simulateCandidateWithoutDeploys(ai, state, candidate, ctx.aiPlayer, ctx)
    if not (skippedDeploy and afterNonDeploy) then
        return nil
    end

    local nextOwnTurn = prepareTurnForPlayer(ai, afterNonDeploy, ctx.aiPlayer)
    local activeThreats = {}
    for _, threatEntry in ipairs(defenseThreatEntries(contracts)) do
        local threatUnit = findThreatUnitAt(ai, nextOwnTurn, threatEntry and threatEntry.unit)
        if threatUnit and num(threatUnit.currentHp or threatUnit.startingHp, 0) > 0 then
            activeThreats[#activeThreats + 1] = threatUnit
        end
    end
    if #activeThreats ~= 1 then
        return nil
    end

    local threatUnit = activeThreats[1]
    local maxEta = clampLimit((opts and opts.maxEta) or 1, 1, 3)
    local contributions = {}
    for _, unit in ipairs((nextOwnTurn and nextOwnTurn.units) or {}) do
        if isRaceEligibleUnit(ai, unit, ctx.aiPlayer) then
            local eta, route = unitThreatEtaAgainstTarget(ai, nextOwnTurn, unit, threatUnit, maxEta, ctx)
            if eta and eta >= 1 and eta <= maxEta then
                local damage = num(ai.calculateDamage and ai:calculateDamage(unit, threatUnit), 0)
                if damage > 0 then
                    contributions[#contributions + 1] = {
                        eta = eta,
                        damage = damage,
                        route = route,
                        unitName = tostring(unit.name or "?")
                    }
                end
            end
        end
    end
    if #contributions == 0 then
        return nil
    end

    table.sort(contributions, function(a, b)
        if num(a.eta, 99) ~= num(b.eta, 99) then
            return num(a.eta, 99) < num(b.eta, 99)
        end
        if num(a.damage, 0) ~= num(b.damage, 0) then
            return num(a.damage, 0) > num(b.damage, 0)
        end
        return tostring(a.unitName or "") < tostring(b.unitName or "")
    end)

    local targetHp = num(threatUnit.currentHp or threatUnit.startingHp, 0)
    local actionsPerTurn = actionCountPerTurn(ai)
    local commandantAutoDamage = commandantAutoDamageAgainstThreat(ai, nextOwnTurn, ctx.aiPlayer, threatUnit)
    for eta = 1, maxEta do
        local available = {}
        for _, entry in ipairs(contributions) do
            if num(entry.eta, 99) <= eta then
                available[#available + 1] = entry
            end
        end
        table.sort(available, function(a, b)
            if num(a.damage, 0) ~= num(b.damage, 0) then
                return num(a.damage, 0) > num(b.damage, 0)
            end
            return tostring(a.unitName or "") < tostring(b.unitName or "")
        end)

        local damage = commandantAutoDamage
        local used = math.min(actionsPerTurn, #available)
        for idx = 1, used do
            damage = damage + num(available[idx].damage, 0)
        end
        if damage >= targetHp then
            return {
                eta = eta,
                damage = damage,
                targetHp = targetHp,
                lethal = true,
                contributors = used,
                commandantAutoDamage = commandantAutoDamage,
                targetName = tostring(threatUnit.name or "?"),
                targetRow = threatUnit.row,
                targetCol = threatUnit.col
            }
        end
    end

    return nil
end

local function computeDefenseThreatRemovalSetup(ai, afterOur, candidate, contracts, ctx)
    if not (ai and afterOur and candidate and contracts and contracts.defenseKind == "pressure" and ctx) then
        return nil
    end

    local nextOwnTurn = prepareTurnForPlayer(ai, afterOur, ctx.aiPlayer)
    local threat = threatPayload(contracts.defenseThreat)
    local threatEntries = (contracts.defenseThreat and contracts.defenseThreat.damagingAttackers)
        or (threat and threat.damagingAttackers)
        or {}
    if #threatEntries == 0 then
        return nil
    end

    local maxEta = clampLimit((ctx.cfg and ctx.cfg.DEFENSE_RACE_MAX_SETUP_ETA) or 4, 1, 6)
    local maxUnitsPerThreat = clampLimit((ctx.cfg and ctx.cfg.DEFENSE_RACE_MAX_SETUP_UNITS) or 10, 4, 20)
    local sourceByUnit = buildDefenseSetupSourceByUnit(ai, afterOur, candidate, ctx.aiPlayer, ctx)
    local survivalCache = {}

    local ownUnits = {}
    for _, unit in ipairs((nextOwnTurn and nextOwnTurn.units) or {}) do
        if isRaceEligibleUnit(ai, unit, ctx.aiPlayer) then
            ownUnits[#ownUnits + 1] = unit
        end
    end

    if #ownUnits == 0 then
        return nil
    end

    local best = nil
    for _, threatEntry in ipairs(threatEntries) do
        local threatUnit = findThreatUnitAt(ai, nextOwnTurn, threatEntry and threatEntry.unit)
        if threatUnit and num(threatUnit.currentHp or threatUnit.startingHp, 0) > 0 then
            local commandantAutoDamage = commandantAutoDamageAgainstThreat(ai, nextOwnTurn, ctx.aiPlayer, threatUnit)
            local rankedOwn = copyArray(ownUnits)
            table.sort(rankedOwn, function(a, b)
                local da = positionDistance(a, threatUnit)
                local db = positionDistance(b, threatUnit)
                if da ~= db then
                    return da < db
                end
                return tostring(a.name or "") < tostring(b.name or "")
            end)

            for idx = 1, math.min(maxUnitsPerThreat, #rankedOwn) do
                local ownUnit = rankedOwn[idx]
                local eta, route = unitThreatEtaAgainstTarget(ai, nextOwnTurn, ownUnit, threatUnit, maxEta, ctx)
                if eta and eta >= 1 and eta <= maxEta then
                    local unitDamage = num(ai.calculateDamage and ai:calculateDamage(ownUnit, threatUnit), 0)
                    local damage = unitDamage + commandantAutoDamage
                    if unitDamage > 0 then
                        local key = unitIdentityKey(ownUnit)
                        local sourceEntry = sourceByUnit[key]
                        local source = "existing"
                        local sourceSignature = nil
                        local sourceRow = nil
                        local sourceCol = nil
                        local deployScore = 0
                        if type(sourceEntry) == "table" then
                            source = sourceEntry.source or "existing"
                            sourceSignature = sourceEntry.signature
                            sourceRow = sourceEntry.row
                            sourceCol = sourceEntry.col
                            if source == "deploy" then
                                deployScore = scoreDeploySetupAction(ai, ctx.currentState, sourceEntry.action, ctx.aiPlayer, ctx)
                            end
                        elseif sourceEntry then
                            source = sourceEntry
                        end
                        local ownHp = num(ownUnit.currentHp or ownUnit.startingHp, 0)
                        if survivalCache[key] == nil then
                            survivalCache[key] = projectedEnemyDamageOnCell(
                                ai,
                                nextOwnTurn,
                                ctx.enemyPlayer,
                                ownUnit.row,
                                ownUnit.col
                            )
                        end
                        local incomingDamage = num(survivalCache[key], 0)
                        local survivalMargin = ownHp - incomingDamage
                        local setup = {
                            eta = eta,
                            damage = damage,
                            unitDamage = unitDamage,
                            commandantAutoDamage = commandantAutoDamage,
                            targetHp = num(threatUnit.currentHp or threatUnit.startingHp, 0),
                            lethal = damage >= num(threatUnit.currentHp or threatUnit.startingHp, 0),
                            route = route,
                            source = source,
                            sourceSignature = sourceSignature,
                            sourceRow = sourceRow,
                            sourceCol = sourceCol,
                            deployScore = deployScore,
                            opportunityCost = sourceCost(source),
                            survives = survivalMargin > 0,
                            survivalMargin = survivalMargin,
                            unitName = tostring(ownUnit.name or "?"),
                            targetName = tostring(threatUnit.name or "?"),
                            targetRow = threatUnit.row,
                            targetCol = threatUnit.col
                        }
                        if setupBetter(setup, best) then
                            best = setup
                        end
                    end
                end
            end
        end
    end

    return best
end

local function annotateDefenseThreatRemovalSetup(ai, beforeState, afterOur, candidate, contracts, ctx)
    local _ = beforeState
    if not (candidate and afterOur and contracts and contracts.defenseKind == "pressure") then
        return nil
    end

    local best = computeDefenseThreatRemovalSetup(ai, afterOur, candidate, contracts, ctx)
    local deploySetup = nil
    if candidate.containsDeploy == true then
        deploySetup = bestCandidateDeployThreatSetup(ai, afterOur, candidate, contracts, ctx)
    end
    if deploySetup and (not best or tostring(best.source or "") == "existing") then
        best = deploySetup
    end
    if not best then
        return nil
    end
    if tostring(best.source or "") == "existing" then
        return nil
    end

    if leavesImmediateNonHubAllyLethal(ai, afterOur, ctx) then
        if ctx and ctx.stats then
            ctx.stats.defensiveThreatRemovalSetupRejectedAllyLethal =
                (ctx.stats.defensiveThreatRemovalSetupRejectedAllyLethal or 0) + 1
        end
        return nil
    end

    candidate.tacticalTags = candidate.tacticalTags or {}
    candidate.tacticalTags.addressesCommandantPressure = true
    candidate.tacticalTags.defensiveThreatRemovalSetup = true
    candidate.tacticalTags.threatRemovalSetupDamage = best.damage
    candidate.tacticalTags.threatRemovalSetupUnitDamage = best.unitDamage or best.damage
    candidate.tacticalTags.threatRemovalSetupCommandantAutoDamage = best.commandantAutoDamage or 0
    candidate.tacticalTags.threatRemovalSetupLethal = best.lethal
    candidate.tacticalTags.threatRemovalSetupUnit = best.unitName
    candidate.tacticalTags.threatRemovalSetupTarget = best.targetName
    candidate.tacticalTags.threatRemovalSetupEta = best.eta
    candidate.tacticalTags.threatRemovalSetupRoute = best.route
    candidate.tacticalTags.threatRemovalSetupSource = best.source
    candidate.tacticalTags.threatRemovalSetupSourceSignature = best.sourceSignature
    candidate.tacticalTags.threatRemovalSetupSourceRow = best.sourceRow
    candidate.tacticalTags.threatRemovalSetupSourceCol = best.sourceCol
    candidate.tacticalTags.threatRemovalSetupDeployScore = best.deployScore
    candidate.tacticalTags.threatRemovalSetupSurvives = best.survives == true
    candidate.tacticalTags.threatRemovalSetupOpportunityCost = best.opportunityCost

    if ctx and ctx.stats then
        ctx.stats.defensiveThreatRemovalSetupCandidates = (ctx.stats.defensiveThreatRemovalSetupCandidates or 0) + 1
        if num(best.eta, 99) <= 1 then
            ctx.stats.defensiveThreatRemovalSetupEtaOne = (ctx.stats.defensiveThreatRemovalSetupEtaOne or 0) + 1
        else
            ctx.stats.defensiveThreatRemovalSetupEtaLong = (ctx.stats.defensiveThreatRemovalSetupEtaLong or 0) + 1
        end
    end

    return best
end

local function itemWinsNow(item, ctx)
    local scoreValue = item and (item.finalScore or item.fastScore) or nil
    return scoreValue and num(scoreValue.tier, 0) >= ctx.score.TIER.WIN_NOW
end

local function markPressureDefenseResolved(candidate, proof, details, ctx)
    if candidate then
        candidate.tacticalTags = candidate.tacticalTags or {}
        candidate.tacticalTags.addressesCommandantPressure = true
        candidate.tacticalTags.preventsImmediateLoss = true
        candidate.tacticalTags.pressureDefenseProof = proof
        candidate.tacticalTags.defenseRaceProof = proof
        candidate.tacticalTags.defenseRaceBestETA = details and finiteNumberOrNil(details.bestETA) or nil
        candidate.tacticalTags.defenseRaceProjectedDamageDelta = details and num(details.projectedDamageDelta, 0) or 0
        candidate.tacticalTags.defenseRaceAttackerDelta = details and num(details.attackerDelta, 0) or 0
        candidate.tacticalTags.defenseRaceLineBlock = details and details.lineBlock == true or false
        if details and details.setupSource then
            candidate.tacticalTags.threatRemovalSetupSource = details.setupSource
        end
        if details and details.setupDamage then
            candidate.tacticalTags.threatRemovalSetupDamage = details.setupDamage
        end
    end
    if ctx and ctx.stats then
        ctx.stats.defenseRaceProof = proof
        ctx.stats.defenseRaceUnresolvedReason = nil
        ctx.stats.defenseRaceBestETA = details and finiteNumberOrNil(details.bestETA) or nil
        ctx.stats.defenseRaceLineBlock = details and details.lineBlock == true or false
    end
    return true
end

local function markPressureDefenseUnresolved(candidate, reason, ctx)
    if candidate then
        candidate.tacticalTags = candidate.tacticalTags or {}
        candidate.tacticalTags.addressesCommandantPressure = false
        candidate.tacticalTags.preventsImmediateLoss = false
        candidate.tacticalTags.pressureDefenseProof = nil
        candidate.tacticalTags.defenseRaceProof = nil
        candidate.tacticalTags.defenseRaceBestETA = nil
        candidate.tacticalTags.pressureDefenseUnresolvedReason = reason
        candidate.tacticalTags.defenseRaceRejectedReason = reason
    end
    if ctx and ctx.stats then
        ctx.stats.defenseRaceUnresolvedReason = reason
    end
    return false
end

local function candidateHasPressureSetupProof(candidate)
    local tags = candidate and candidate.tacticalTags or {}
    return tags.defensiveThreatRemovalSetup == true
        or tags.clearsCommandantPressure == true
        or finiteNumberOrNil(tags.threatRemovalSetupEta) ~= nil
end

local function pressureDefenseDelta(defenseThreat, afterThreat)
    local beforeProjected = threatProjectedDamage(defenseThreat)
    local beforeCount = threatAttackerCount(defenseThreat)
    if not afterThreat then
        return {
            beforeProjected = beforeProjected,
            afterProjected = beforeProjected,
            beforeCount = beforeCount,
            afterCount = beforeCount,
            projectedDamageDelta = 0,
            attackerDelta = 0,
            reduced = false,
            cleared = false
        }
    end
    local afterProjected = threatProjectedDamage(afterThreat)
    local afterCount = threatAttackerCount(afterThreat)
    local reduced = afterProjected <= 0
        or afterProjected < beforeProjected
        or afterCount < beforeCount
    local cleared = afterProjected <= 0 or afterCount <= 0 or not threatHasImmediateDanger(afterThreat)
    return {
        beforeProjected = beforeProjected,
        afterProjected = afterProjected,
        beforeCount = beforeCount,
        afterCount = afterCount,
        projectedDamageDelta = beforeProjected - afterProjected,
        attackerDelta = beforeCount - afterCount,
        reduced = reduced,
        cleared = cleared
    }
end

function M._simulatePressureDefenseAction(ai, state, playerId, ctx, action)
    if not (ai and state and playerId and action and action.type and action.type ~= "skip") then
        return state
    end
    if ctx and ctx.cache and ctx.cache.simulate then
        return ctx.cache.simulate(ai, state, {action}, playerId, ctx)
    end
    if ai.simulateActionSequenceForPlayer then
        return ai:simulateActionSequenceForPlayer(state, {action}, playerId, {})
    end
    return nil
end

function M._pressureDefenseUnsafeFillerAfterResolved(ai, beforeState, candidate, contracts, ctx)
    if not (ctx and ctx.cfg and ctx.cfg.DEFEND_NOW_AVOID_UNSAFE_FILLER ~= false) then
        return false, nil
    end
    if not (ai and beforeState and candidate and candidate.actions and contracts and contracts.defenseKind == "pressure") then
        return false, nil
    end
    if #(candidate.actions or {}) < 2 then
        return false, nil
    end

    local defenseThreat = contracts.defenseThreat
    local currentState = beforeState
    local resolved = false
    for _, action in ipairs(candidate.actions or {}) do
        if resolved
            and action
            and action.type == "move"
            and action.target
            and not actionTouchesThreatBlock(action, defenseThreat)
            and not actionTargetsThreatUnit(action, defenseThreat) then
            local mover = getUnitAt(ai, currentState, action.unit and action.unit.row, action.unit and action.unit.col)
            local suicidal = mover
                and ai.isSuicidalMovement
                and ai:isSuicidalMovement(currentState, {row = action.target.row, col = action.target.col}, mover)
            if suicidal then
                candidate.tacticalTags = candidate.tacticalTags or {}
                candidate.tacticalTags.unsafeDefenseFiller = true
                candidate.tacticalTags.unsafeDefenseFillerAction = actionSignature(ctx, action)
                if ctx and ctx.stats then
                    ctx.stats.unsafeDefenseFillerRejected = num(ctx.stats.unsafeDefenseFillerRejected, 0) + 1
                    ctx.stats.unsafeDefenseFillerAction = candidate.tacticalTags.unsafeDefenseFillerAction
                end
                return true, "unsafe_pressure_defense_filler"
            end
        end

        currentState = M._simulatePressureDefenseAction(ai, currentState, ctx and ctx.aiPlayer, ctx, action)
        if not currentState then
            return false, nil
        end

        local afterThreat = ctx
            and ctx.cache
            and ctx.cache.threat
            and ctx.cache.threat(ai, currentState, ctx.aiPlayer, ctx.enemyPlayer, ctx)
            or nil
        if pressureDefenseDelta(defenseThreat, afterThreat).cleared then
            resolved = true
        end
    end

    return false, nil
end

local function isThreatAttackerRanged(ai, threatEntry)
    local unit = threatEntry and threatEntry.unit
    if not unit then
        return false
    end

    local attackRange = finiteNumberOrNil(unit.atkRange or unit.range)
    if not attackRange and ai and ai.unitsInfo and ai.unitsInfo.getUnitAttackRange then
        local ok, resolved = pcall(ai.unitsInfo.getUnitAttackRange, ai.unitsInfo, unit, "TOURNAMENT_DEFENSE_RACE")
        if ok then
            attackRange = finiteNumberOrNil(resolved)
        end
    end
    if not attackRange and ai and ai.unitHasTag and ai:unitHasTag(unit, "ranged") then
        attackRange = 2
    end

    return num(attackRange, 1) >= 2
end

local function threatHasRangedAttacker(ai, defenseThreat)
    local threat = threatPayload(defenseThreat)
    for _, entry in ipairs((defenseThreat and defenseThreat.damagingAttackers) or (threat and threat.damagingAttackers) or {}) do
        if isThreatAttackerRanged(ai, entry) then
            return true
        end
    end
    return false
end

local function threatHasLineBlockImmuneRangedAttacker(ai, defenseThreat)
    local threat = threatPayload(defenseThreat)
    for _, entry in ipairs((defenseThreat and defenseThreat.damagingAttackers) or (threat and threat.damagingAttackers) or {}) do
        local unit = entry and entry.unit
        if unit and isThreatAttackerRanged(ai, entry) and tostring(unit.name or "") == "Artillery" then
            return true
        end
    end
    return false
end

local function contractDefenseRaceTTD(contracts)
    local ttd = finiteNumberOrNil(contracts and contracts.defenseRaceTTD)
    if not ttd then
        return math.huge
    end
    return ttd
end

local function candidatePressureSetupFromTags(candidate)
    local tags = candidate and candidate.tacticalTags or {}
    if not candidateHasPressureSetupProof(candidate) then
        return nil
    end
    local source = tostring(tags.threatRemovalSetupSource or "")
    if source == "existing" then
        return nil
    end
    local eta = finiteNumberOrNil(tags.threatRemovalSetupEta)
    if not eta then
        eta = 1
    end
    return {
        eta = eta,
        damage = num(tags.threatRemovalSetupDamage, 0),
        lethal = tags.threatRemovalSetupLethal == true,
        source = source ~= "" and source or nil,
        sourceSignature = tags.threatRemovalSetupSourceSignature,
        sourceRow = tags.threatRemovalSetupSourceRow,
        sourceCol = tags.threatRemovalSetupSourceCol,
        deployScore = tags.threatRemovalSetupDeployScore,
        route = tags.threatRemovalSetupRoute,
        survives = tags.threatRemovalSetupSurvives == true,
        opportunityCost = num(tags.threatRemovalSetupOpportunityCost, 0),
        unitName = tags.threatRemovalSetupUnit,
        targetName = tags.threatRemovalSetupTarget
    }
end

local function countCandidateThreatAttacks(candidate, threatResult)
    local count = 0
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if actionTargetsThreatUnit(action, threatResult) then
            count = count + 1
        end
    end
    return count
end

local function directFocusFireReductionAvailable(ai, state, contracts, ctx)
    if not (ai and state and contracts and contracts.defenseKind == "pressure" and ctx and ai.collectLegalActions) then
        return false
    end
    if ctx._directFocusFireReductionAvailable ~= nil then
        return ctx._directFocusFireReductionAvailable == true
    end

    local defenseThreat = contracts.defenseThreat
    local beforeProjected = threatProjectedDamage(defenseThreat)
    local beforeCount = threatAttackerCount(defenseThreat)
    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local firstEntries = ai:collectLegalActions(state, {
        aiPlayer = ctx.aiPlayer,
        includeMove = false,
        includeAttack = true,
        includeRepair = false,
        includeDeploy = false,
        allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    }) or {}

    local function damagingThreatAttack(entryState, action)
        if not (actionTargetsThreatUnit(action, defenseThreat) and isFactionAttack(ctx, entryState, action, ctx.aiPlayer)) then
            return false
        end
        local attacker = getUnitAt(ai, entryState, action.unit and action.unit.row, action.unit and action.unit.col)
        local target = getActionTargetUnit(ai, entryState, action)
        return attacker and target and num(ai.calculateDamage and ai:calculateDamage(attacker, target), 0) > 0
    end

    local function pressureReduced(afterState)
        if not (afterState and ctx.cache and ctx.cache.threat) then
            return false
        end
        local afterThreat = ctx.cache.threat(ai, afterState, ctx.aiPlayer, ctx.enemyPlayer, ctx)
        local afterProjected = threatProjectedDamage(afterThreat)
        local afterCount = threatAttackerCount(afterThreat)
        return afterProjected <= 0 or afterProjected < beforeProjected or afterCount < beforeCount
    end

    for _, firstEntry in ipairs(firstEntries) do
        local firstAction = firstEntry and firstEntry.action or nil
        if damagingThreatAttack(state, firstAction) then
            local afterFirst = ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, {firstAction}, ctx.aiPlayer, ctx)
            if pressureReduced(afterFirst) then
                ctx._directFocusFireReductionAvailable = true
                return true
            end

            if afterFirst and actionCountPerTurn(ai) >= 2 then
                local secondEntries = ai:collectLegalActions(afterFirst, {
                    aiPlayer = ctx.aiPlayer,
                    includeMove = false,
                    includeAttack = true,
                    includeRepair = false,
                    includeDeploy = false,
                    allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
                }) or {}
                for _, secondEntry in ipairs(secondEntries) do
                    local secondAction = secondEntry and secondEntry.action or nil
                    if damagingThreatAttack(afterFirst, secondAction) then
                        local afterSecond = ctx.cache and ctx.cache.simulate
                            and ctx.cache.simulate(ai, afterFirst, {secondAction}, ctx.aiPlayer, ctx)
                        if pressureReduced(afterSecond) then
                            ctx._directFocusFireReductionAvailable = true
                            return true
                        end
                    end
                end
            end
        end
    end

    ctx._directFocusFireReductionAvailable = false
    return false
end

local function candidatePressureDefenseResolved(ai, candidate, afterOur, contracts, ctx)
    if not (contracts and contracts.defenseKind == "pressure") then
        return false
    end

    candidate = candidate or {}
    candidate.tacticalTags = candidate.tacticalTags or {}
    local defenseThreat = contracts.defenseThreat
    local targetsThreat = candidateTargetsThreatUnit(candidate, defenseThreat)
    local touchesBlock = candidateTouchesThreatBlock(candidate, defenseThreat)
    if targetsThreat then
        candidate.tacticalTags.targetsCommandantThreat = true
    end

    local afterThreat = nil
    if afterOur and ctx and ctx.cache and ctx.cache.threat then
        afterThreat = ctx.cache.threat(ai, afterOur, ctx.aiPlayer, ctx.enemyPlayer, ctx)
    end
    local delta = pressureDefenseDelta(defenseThreat, afterThreat)
    local unsafeFiller, unsafeFillerReason =
        M._pressureDefenseUnsafeFillerAfterResolved(ai, ctx and ctx.currentState, candidate, contracts, ctx)
    if unsafeFiller then
        return markPressureDefenseUnresolved(candidate, unsafeFillerReason, ctx)
    end
    local setup = candidatePressureSetupFromTags(candidate)
    if not setup and afterOur then
        setup = computeDefenseThreatRemovalSetup(ai, afterOur, candidate, contracts, ctx)
    end
    local deploySetup = nil
    if candidate.containsDeploy == true and afterOur then
        deploySetup = bestCandidateDeployThreatSetup(ai, afterOur, candidate, contracts, ctx)
        if deploySetup and (not setup or tostring(setup.source or "") == "existing") then
            setup = deploySetup
        end
    end
    local setupFromAction = setup and setup.source and setup.source ~= "existing"

    local defenseTTD = contractDefenseRaceTTD(contracts)
    local hasFiniteTTD = defenseTTD < math.huge
    local winRaceEstimate = contracts and contracts.defenseRaceWinRaceEstimate == true
    local rangedThreat = threatHasRangedAttacker(ai, defenseThreat)
    local lineBlockImmuneRangedThreat = threatHasLineBlockImmuneRangedAttacker(ai, defenseThreat)
    local directThreatAttackActions = num(contracts and contracts.directThreatAttackActions, 0)
    local directThreatReductionActions = num(contracts and contracts.directThreatReductionActions, 0)
    local moveThreatAttackActions = num(contracts and contracts.moveThreatAttackActions, 0)
    local spendsFactionAttack = candidate and candidate.hasFactionAttack == true
    local directThreatDamage = candidateThreatAttackDamage(ai, ctx and ctx.currentState, candidate, defenseThreat, ctx and ctx.aiPlayer, ctx)
    local zeroDamageThreatAttack = targetsThreat and spendsFactionAttack and directThreatDamage <= 0
    local threatAttackCount = countCandidateThreatAttacks(candidate, defenseThreat)
    local spendsAttackOffThreat = candidateSpendsAttackOffThreat(ai, ctx and ctx.currentState, candidate, defenseThreat, ctx and ctx.aiPlayer, ctx)
    local movesCurrentThreatResponder = candidateMovesCurrentThreatResponder(
        ai,
        ctx and ctx.currentState,
        candidate,
        defenseThreat,
        ctx and ctx.aiPlayer,
        ctx
    )
    local evacuatesDefenseBlocker = candidate.tacticalTags.defensiveBlockerEvacuation == true
        or candidateEvacuatesDefenseBlocker(ai, ctx and ctx.currentState, candidate, defenseThreat, ctx and ctx.aiPlayer)
    if evacuatesDefenseBlocker then
        candidate.tacticalTags.defensiveBlockerEvacuation = true
    end
    local availableDeploySetup = nil
    local availableDeployReduction = nil
    if ctx then
        if ctx._pressureDeploySetupComputed ~= true then
            ctx._pressureDeploySetup = bestCurrentDeployThreatSetup(ai, ctx.currentState, contracts, ctx)
            ctx._pressureDeploySetupComputed = true
        end
        availableDeploySetup = ctx._pressureDeploySetup
        if ctx._pressureDeployReductionComputed ~= true then
            ctx._pressureDeployReduction = bestCurrentDeployThreatReduction(ai, ctx.currentState, contracts, ctx)
            ctx._pressureDeployReductionComputed = true
        end
        availableDeployReduction = ctx._pressureDeployReduction
    end
    local concreteDeploySetup = candidate.containsDeploy == true
        and deploySetup
        and num(deploySetup.eta, 99) <= 1
        and num(deploySetup.damage, 0) > 0
    local concreteDeploySetupClearsThreat = concreteDeploySetup == true
        and deploySetup
        and deploySetup.lethal == true
    local existingSetupPreservedByDeploy = candidate.containsDeploy == true
        and setup
        and not setupFromAction
        and num(setup and setup.eta, 99) <= 1
        and num(setup and setup.damage, 0) > 0
        and spendsAttackOffThreat ~= true
        and movesCurrentThreatResponder ~= true

    if candidate.tacticalTags.winsNow == true then
        return markPressureDefenseResolved(candidate, "win_now", {
            bestETA = 0,
            projectedDamageDelta = delta.projectedDamageDelta,
            attackerDelta = delta.attackerDelta
        }, ctx)
    end

    if targetsThreat and delta.cleared then
        return markPressureDefenseResolved(candidate, "immediate_removal", {
            bestETA = 0,
            projectedDamageDelta = delta.projectedDamageDelta,
            attackerDelta = delta.attackerDelta,
            setupDamage = num(setup and setup.damage, 0)
        }, ctx)
    end

    if targetsThreat and delta.reduced then
        return markPressureDefenseResolved(candidate, "focus_fire", {
            bestETA = 0,
            projectedDamageDelta = delta.projectedDamageDelta,
            attackerDelta = delta.attackerDelta,
            setupDamage = num(setup and setup.damage, 0)
        }, ctx)
    end

    if zeroDamageThreatAttack and not delta.reduced and not touchesBlock then
        if not (setupFromAction and setup and setup.lethal == true and num(setup.eta, 99) < defenseTTD) then
            return markPressureDefenseUnresolved(candidate, "threat_attack_zero_damage", ctx)
        end
    end

    if targetsThreat
        and not delta.reduced
        and threatAttackCount < math.min(2, actionCountPerTurn(ai))
        and directFocusFireReductionAvailable(ai, ctx and ctx.currentState, contracts, ctx) then
        return markPressureDefenseUnresolved(candidate, "focus_fire_available_before_nonreducing_setup", ctx)
    end

    if directThreatAttackActions > 0
        and spendsFactionAttack
        and not targetsThreat
        and not delta.reduced
        and not touchesBlock then
        return markPressureDefenseUnresolved(candidate, "spent_attack_off_active_commandant_threat", ctx)
    end

    if lineBlockImmuneRangedThreat
        and directThreatAttackActions > 0
        and not targetsThreat
        and not delta.reduced then
        return markPressureDefenseUnresolved(candidate, "missed_unblockable_ranged_threat_source", ctx)
    end

    if directThreatReductionActions > 0
        and not targetsThreat
        and not delta.reduced
        and not touchesBlock then
        return markPressureDefenseUnresolved(candidate, "missed_immediate_threat_response", ctx)
    end

    if targetsThreat
        and not delta.reduced
        and availableDeploySetup
        and setup
        and num(availableDeploySetup.eta, 99) <= num(setup.eta, 99)
        and num(availableDeploySetup.damage, 0) >= num(setup.damage, 0)
        and (
            candidate.containsDeploy ~= true
            or tostring(setup.source or "") ~= "deploy"
            or (
                tostring(availableDeploySetup.sourceSignature or "") ~= ""
                and tostring(setup.sourceSignature or "") ~= tostring(availableDeploySetup.sourceSignature or "")
            )
        ) then
        return markPressureDefenseUnresolved(candidate, "deploy_counter_available_before_nonreducing_threat_chip", ctx)
    end

    if availableDeployReduction
        and not delta.reduced
        and not targetsThreat then
        return markPressureDefenseUnresolved(candidate, "deploy_pressure_reduction_available", ctx)
    end

    if (directThreatAttackActions + moveThreatAttackActions) > 0
        and candidate.hasFactionAttack ~= true
        and not targetsThreat
        and not delta.reduced
        and not (touchesBlock and rangedThreat)
        and not concreteDeploySetup
        and not existingSetupPreservedByDeploy
        and (setup or evacuatesDefenseBlocker or candidateHasPressureSetupProof(candidate)) then
        return markPressureDefenseUnresolved(candidate, "move_setup_deferred_available_threat_attack", ctx)
    end

    if availableDeploySetup
        and setupFromAction
        and tostring(setup and setup.source or "") == "move"
        and (
            num(availableDeploySetup.eta, 99) < num(setup and setup.eta, 99)
            or (
                num(availableDeploySetup.eta, 99) == num(setup and setup.eta, 99)
                and num(availableDeploySetup.damage, 0) >= num(setup and setup.damage, 0)
            )
        ) then
        return markPressureDefenseUnresolved(candidate, "deploy_counter_available_before_move_setup", ctx)
    end

    if availableDeploySetup
        and spendsAttackOffThreat
        and not delta.reduced
        and not touchesBlock
        and num(availableDeploySetup.eta, 99) <= math.max(1, num(setup and setup.eta, 99)) then
        return markPressureDefenseUnresolved(candidate, "deploy_counter_available_before_side_attack", ctx)
    end

    if moveThreatAttackActions > 0
        and candidate.hasFactionAttack ~= true
        and evacuatesDefenseBlocker
        and not concreteDeploySetupClearsThreat
        and not existingSetupPreservedByDeploy
        and not delta.reduced then
        return markPressureDefenseUnresolved(candidate, "move_threat_attack_available_before_evacuation", ctx)
    end

    if availableDeploySetup
        and setupFromAction
        and tostring(setup and setup.source or "") == "deploy"
        and evacuatesDefenseBlocker
        and tostring(availableDeploySetup.sourceSignature or "") ~= ""
        and tostring(setup and setup.sourceSignature or "") ~= tostring(availableDeploySetup.sourceSignature or "")
        and num(availableDeploySetup.eta, 99) <= num(setup and setup.eta, 99)
        and num(availableDeploySetup.damage, 0) >= num(setup and setup.damage, 0) then
        return markPressureDefenseUnresolved(candidate, "deploy_counter_available_without_blocker_evacuation", ctx)
    end

    if candidate.containsDeploy == true
        and setup
        and not targetsThreat
        and not delta.reduced
        and not touchesBlock then
        local boardOnlyPlan = boardOnlyThreatRemovalPlan(ai, ctx and ctx.currentState, candidate, contracts, ctx, {
            maxEta = 1
        })
        if boardOnlyPlan
            and boardOnlyPlan.lethal == true
            and num(boardOnlyPlan.eta, 99) <= num(setup.eta, 99)
            and ((not hasFiniteTTD) or num(boardOnlyPlan.eta, 99) < defenseTTD) then
            candidate.tacticalTags.redundantDefenseDeploy = true
            candidate.tacticalTags.boardOnlyDefenseDamage = boardOnlyPlan.damage
            candidate.tacticalTags.boardOnlyDefenseTargetHp = boardOnlyPlan.targetHp
            if ctx and ctx.stats then
                ctx.stats.redundantDefenseDeployRejected = (ctx.stats.redundantDefenseDeployRejected or 0) + 1
            end
            return markPressureDefenseUnresolved(candidate, "redundant_defense_deploy_board_line_covers_threat", ctx)
        end
    end

    if spendsAttackOffThreat
        and evacuatesDefenseBlocker
        and candidate.containsDeploy ~= true
        and not targetsThreat
        and not delta.reduced
        and not touchesBlock then
        return markPressureDefenseUnresolved(candidate, "evacuated_blocker_then_spent_attack_off_threat", ctx)
    end

    if spendsAttackOffThreat
        and setupFromAction
        and tostring(setup and setup.source or "") == "move"
        and not targetsThreat
        and not delta.reduced
        and not touchesBlock then
        return markPressureDefenseUnresolved(candidate, "spent_attack_before_concrete_defense", ctx)
    end

    if touchesBlock and rangedThreat and delta.reduced then
        if setup and ((not hasFiniteTTD) or num(setup.eta, 99) < defenseTTD) then
            return markPressureDefenseResolved(candidate, "ranged_line_block", {
                bestETA = setup.eta,
                setupSource = setup.source,
                setupDamage = setup.damage,
                projectedDamageDelta = delta.projectedDamageDelta,
                attackerDelta = delta.attackerDelta,
                lineBlock = true
            }, ctx)
        end
        return markPressureDefenseUnresolved(candidate, "line_block_without_removal_plan", ctx)
    end

    if targetsThreat and setup and num(setup.eta, 99) <= 1 then
        if setupFromAction then
            candidate.tacticalTags.defensiveThreatRemovalSetup = true
        end
        return markPressureDefenseResolved(candidate, "reinforce_eta1", {
            bestETA = setup.eta,
            setupSource = setup.source,
            setupDamage = setup.damage,
            projectedDamageDelta = delta.projectedDamageDelta,
            attackerDelta = delta.attackerDelta
        }, ctx)
    end

    if existingSetupPreservedByDeploy then
        candidate.tacticalTags.defensiveThreatRemovalSetup = true
        return markPressureDefenseResolved(candidate, "reinforce_eta1", {
            bestETA = setup.eta,
            setupSource = setup.source,
            setupDamage = setup.damage,
            projectedDamageDelta = delta.projectedDamageDelta,
            attackerDelta = delta.attackerDelta
        }, ctx)
    end

    if concreteDeploySetup then
        candidate.tacticalTags.defensiveThreatRemovalSetup = true
        return markPressureDefenseResolved(candidate, "reinforce_eta1", {
            bestETA = deploySetup.eta,
            setupSource = deploySetup.source,
            setupDamage = deploySetup.damage,
            projectedDamageDelta = delta.projectedDamageDelta,
            attackerDelta = delta.attackerDelta
        }, ctx)
    end

    if evacuatesDefenseBlocker and setup then
        if (not hasFiniteTTD) or num(setup.eta, 99) < defenseTTD then
            candidate.tacticalTags.defensiveThreatRemovalSetup = true
            return markPressureDefenseResolved(candidate, "evacuate_blocker", {
                bestETA = setup.eta,
                setupSource = setup.source,
                setupDamage = setup.damage,
                projectedDamageDelta = delta.projectedDamageDelta,
                attackerDelta = delta.attackerDelta
            }, ctx)
        end
        return markPressureDefenseUnresolved(candidate, "evacuation_setup_eta_not_survivable", ctx)
    end

    if setupFromAction and setup and num(setup.eta, 99) <= 1 then
        candidate.tacticalTags.defensiveThreatRemovalSetup = true
        return markPressureDefenseResolved(candidate, "reinforce_eta1", {
            bestETA = setup.eta,
            setupSource = setup.source,
            setupDamage = setup.damage,
            projectedDamageDelta = delta.projectedDamageDelta,
            attackerDelta = delta.attackerDelta
        }, ctx)
    end

    if setupFromAction and setup and num(setup.eta, 99) > 1 then
        if winRaceEstimate then
            return markPressureDefenseUnresolved(candidate, "setup_rejected_by_win_race", ctx)
        end
        if (not hasFiniteTTD) or num(setup.eta, 99) < defenseTTD then
            candidate.tacticalTags.defensiveThreatRemovalSetup = true
            return markPressureDefenseResolved(candidate, "reinforce_eta_gt1", {
                bestETA = setup.eta,
                setupSource = setup.source,
                setupDamage = setup.damage,
                projectedDamageDelta = delta.projectedDamageDelta,
                attackerDelta = delta.attackerDelta
            }, ctx)
        end
        return markPressureDefenseUnresolved(candidate, "setup_eta_not_survivable", ctx)
    end

    if delta.reduced then
        return markPressureDefenseResolved(candidate, "reduced_projected_pressure", {
            bestETA = finiteNumberOrNil(setup and setup.eta) or 0,
            projectedDamageDelta = delta.projectedDamageDelta,
            attackerDelta = delta.attackerDelta
        }, ctx)
    end

    return markPressureDefenseUnresolved(candidate, "pressure_not_reduced", ctx)
end

local function itemAddressesActiveDefense(ai, item, contracts, ctx)
    if not (contracts and contracts.defenseActive == true) then
        return true
    end
    if not item then
        return false
    end
    if itemWinsNow(item, ctx) then
        return true
    end

    local candidate = item.candidate
    local defenseThreat = contracts.defenseThreat

    if contracts.defenseKind == "pressure" then
        if candidateTargetsThreatUnit(candidate, defenseThreat) then
            candidate.tacticalTags = candidate.tacticalTags or {}
            candidate.tacticalTags.targetsCommandantThreat = true
        end

        if contracts.defenseRaceWinRaceConfirmed == true
            and candidate
            and candidate.hasFactionAttack == true
            and candidate.combatSafety
            and candidate.combatSafety.safe == true then
            return markPressureDefenseResolved(candidate, "win_race", {
                bestETA = finiteNumberOrNil(contracts.defenseRaceTTW),
                projectedDamageDelta = 0,
                attackerDelta = 0
            }, ctx)
        end

        return candidatePressureDefenseResolved(ai, candidate, item.afterOur, contracts, ctx)
    end

    local defendsImmediate = candidate and candidate.tacticalTags and candidate.tacticalTags.preventsImmediateLoss == true
    if item.afterOur and ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal then
        local stillLethal = ctx.threatModel.hasImmediateCommandantLethal(
            ai,
            item.afterOur,
            ctx.enemyPlayer,
            ctx.aiPlayer,
            ctx
        ) == true
        defendsImmediate = not stillLethal
    end
    if candidate then
        candidate.tacticalTags = candidate.tacticalTags or {}
        candidate.tacticalTags.preventsImmediateLoss = defendsImmediate == true
    end
    return defendsImmediate == true
end

local function resolveAttackRange(ai, unit)
    if not unit then
        return 1
    end

    local attackRange = num(unit.atkRange or unit.range, nil)
    if attackRange then
        return attackRange
    end

    if ai and ai.unitsInfo and ai.unitsInfo.getUnitAttackRange then
        local ok, resolved = pcall(ai.unitsInfo.getUnitAttackRange, ai.unitsInfo, unit, "TOURNAMENT_COMBAT_KIND")
        if ok and resolved then
            return num(resolved, 1)
        end
    end

    if ai and ai.unitHasTag and ai:unitHasTag(unit, "ranged") then
        return 2
    end

    return 1
end

local function getAttackKind(ai, attacker)
    local attackRange = resolveAttackRange(ai, attacker)
    if attackRange >= 2 then
        return "ranged", attackRange
    end
    return "melee", attackRange
end

local function combatClassValue(combatClass)
    return num(COMBAT_CLASS_PRIORITY[tostring(combatClass or "unsafe_or_losing_attack")], 0)
end

local function combatClassForceValue(combatClass)
    return num(COMBAT_CLASS_FORCE_VALUE[tostring(combatClass or "unsafe_or_losing_attack")], 0)
end

local function compareCombatCandidates(a, b, ctx)
    if not a then
        return false
    end
    if not b then
        return true
    end

    local av = combatClassValue(a.combatClass or (a.candidate and a.candidate.combatClass))
    local bv = combatClassValue(b.combatClass or (b.candidate and b.candidate.combatClass))
    if av ~= bv then
        return av > bv
    end

    local aSafety = a.combatSafety or (a.candidate and a.candidate.combatSafety)
    local bSafety = b.combatSafety or (b.candidate and b.candidate.combatSafety)
    local asafe = (aSafety and aSafety.safe == true) and 1 or 0
    local bsafe = (bSafety and bSafety.safe == true) and 1 or 0
    if asafe ~= bsafe then
        return asafe > bsafe
    end

    local avalue = a.combatValue or (a.candidate and a.candidate.combatValue) or {}
    local bvalue = b.combatValue or (b.candidate and b.candidate.combatValue) or {}
    local adamage = num(avalue.damage or avalue.totalDamage, 0)
    local bdamage = num(bvalue.damage or bvalue.totalDamage, 0)
    if adamage ~= bdamage then
        return adamage > bdamage
    end

    local akills = num(avalue.kills, 0)
    local bkills = num(bvalue.kills, 0)
    if akills ~= bkills then
        return akills > bkills
    end

    if ctx and ctx.score then
        return ctx.score.isBetter(a.finalScore or a.fastScore, b.finalScore or b.fastScore)
    end

    return false
end

local function candidateHasSkipAction(candidate)
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action and action.type == "skip" then
            return true
        end
    end
    return false
end

local function candidateHasNeutralOnlyAttack(candidate)
    return candidate
        and candidate.containsAttack == true
        and candidate.hasFactionAttack ~= true
end

local function candidateHasStrategicNeutralAttack(ai, state, candidate, ctx)
    if not candidateHasNeutralOnlyAttack(candidate) then
        return false
    end
    if candidate._strategicNeutralAttack ~= nil then
        return candidate._strategicNeutralAttack == true
    end

    local strategic = false
    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "attack" then
            local faction = isFactionAttack and isFactionAttack(ctx, state, action, ctx and ctx.aiPlayer) == true
            if not faction then
                local target = getActionTargetUnit(ai, state, action)
                local targetPlayer = num(target and target.player, 0)
                if target and (target.name == "Rock" or targetPlayer == 0) and ai and ai.isStrategicRockAttack then
                    local ok, result = pcall(ai.isStrategicRockAttack, ai, state, action, {
                        aiPlayer = ctx and ctx.aiPlayer,
                        target = target
                    })
                    if ok and result == true then
                        strategic = true
                        break
                    end
                end
            end
        end
    end

    candidate._strategicNeutralAttack = strategic == true
    return strategic == true
end

local function neutralAttackTarget(ai, state, action)
    if not (action and action.type == "attack" and action.target) then
        return nil
    end

    local target = getActionTargetUnit(ai, state, action)
    if target then
        local targetPlayer = num(target.player, nil)
        if target.name == "Rock" or targetPlayer == 0 then
            return target
        end
        return nil
    end

    for _, building in ipairs((state and state.neutralBuildings) or {}) do
        if building and building.row == action.target.row and building.col == action.target.col then
            return {
                name = building.name or "Rock",
                player = 0,
                row = building.row,
                col = building.col,
                currentHp = building.currentHp,
                startingHp = building.startingHp
            }
        end
    end

    return nil
end

local function isStrategicNeutralAttack(ai, state, action, target, ctx)
    if not (target and (target.name == "Rock" or num(target.player, -1) == 0)) then
        return false
    end
    if not (ai and ai.isStrategicRockAttack) then
        return false
    end

    local ok, result = pcall(ai.isStrategicRockAttack, ai, state, action, {
        aiPlayer = ctx and ctx.aiPlayer,
        target = target
    })
    return ok and result == true
end

local function isDisallowedNeutralAttackAction(ai, state, action, ctx)
    if not (action and action.type == "attack") then
        return false
    end
    if isFactionAttack and isFactionAttack(ctx, state, action, ctx and ctx.aiPlayer) == true then
        return false
    end

    local target = neutralAttackTarget(ai, state, action)
    if not target then
        return false
    end

    return not isStrategicNeutralAttack(ai, state, action, target, ctx)
end

local function itemHasDisallowedNeutralAttack(ai, state, ctx, item)
    local candidate = item and item.candidate
    if not (candidate and candidate.containsAttack == true) then
        return false
    end

    local currentState = state
    for _, action in ipairs(candidate.actions or {}) do
        if isDisallowedNeutralAttackAction(ai, currentState, action, ctx) then
            return true
        end
        if currentState then
            currentState = (ctx and ctx.cache and ctx.cache.simulate)
                and ctx.cache.simulate(ai, currentState, {action}, ctx.aiPlayer, ctx)
                or (ai and ai.simulateActionSequenceForPlayer and ai:simulateActionSequenceForPlayer(currentState, {action}, ctx.aiPlayer, {}))
        end
    end

    return false
end

local function nonCombatProgressValue(ai, state, item, ctx)
    if not item or not item.candidate or item.candidate.hasFactionAttack == true or not item.afterOur then
        return -999999
    end

    local before = ctx and ctx.cache and ctx.cache.features and ctx.cache.features(ai, state, ctx.aiPlayer, ctx) or nil
    local after = ctx and ctx.cache and ctx.cache.features and ctx.cache.features(ai, item.afterOur, ctx.aiPlayer, ctx) or nil
    if not before or not after then
        return -999999
    end

    local distanceDelta = num(before.closestOwnUnitToEnemyHub, 99) - num(after.closestOwnUnitToEnemyHub, 99)
    local attackDelta = num(after.availableFactionAttackActions, 0) - num(before.availableFactionAttackActions, 0)
    local commandantDelta = num(after.availableCommandantAttackActions, 0) - num(before.availableCommandantAttackActions, 0)
    local commandantPressureDelta = num(after.commandantPressure, 0) - num(before.commandantPressure, 0)

    local progress = 0
    progress = progress + (distanceDelta * num(ctx.cfg.CONVERSION_NONCOMBAT_ADVANCE_WEIGHT, 900))
    progress = progress + (math.max(0, attackDelta) * num(ctx.cfg.CONVERSION_NONCOMBAT_ATTACK_SETUP_WEIGHT, 700))
    progress = progress + (math.max(0, commandantDelta) * num(ctx.cfg.CONVERSION_NONCOMBAT_COMMANDANT_SETUP_WEIGHT, 1300))
    progress = progress + (math.max(0, commandantPressureDelta) * num(ctx.cfg.CONVERSION_NONCOMBAT_COMMANDANT_PRESSURE_WEIGHT, 18))

    if distanceDelta <= 0 and attackDelta <= 0 and commandantDelta <= 0 and commandantPressureDelta <= 0 then
        progress = progress - num(ctx.cfg.CONVERSION_NONCOMBAT_STAGNATION_PENALTY, 1150)
    end

    if item.candidate.containsDeploy == true then
        progress = progress - num(ctx.cfg.CONVERSION_NONCOMBAT_DEPLOY_PENALTY, 780)
    end
    if item.candidate.containsAttack == true then
        progress = progress - num(ctx.cfg.CONVERSION_NONCOMBAT_NEUTRAL_ATTACK_PENALTY, 720)
        if not candidateHasStrategicNeutralAttack(ai, state, item.candidate, ctx) then
            progress = progress - num(ctx.cfg.CONVERSION_NONSTRATEGIC_NEUTRAL_ATTACK_EXTRA_PENALTY, 1200)
        end
    end

    return progress
end

local function preferProgressiveNonCombat(ai, state, candidateItem, bestItem, ctx, contracts)
    if not candidateItem then
        return false
    end
    if not bestItem then
        return true
    end

    local candidateScore = candidateItem.finalScore or candidateItem.fastScore
    local bestScore = bestItem.finalScore or bestItem.fastScore

    if not contracts or contracts.conversionActive ~= true or contracts.defenseActive == true then
        return ctx.score.isBetter(candidateScore, bestScore)
    end

    local margin = num(ctx.cfg.CONVERSION_NONCOMBAT_PROGRESS_MARGIN, 260)
    local candidateProgress = nonCombatProgressValue(ai, state, candidateItem, ctx)
    local bestProgress = nonCombatProgressValue(ai, state, bestItem, ctx)
    local candidateNeutralAttack = candidateHasNeutralOnlyAttack(candidateItem.candidate)
    local bestNeutralAttack = candidateHasNeutralOnlyAttack(bestItem.candidate)
    if candidateNeutralAttack ~= bestNeutralAttack then
        local overrideMargin = num(ctx.cfg.CONVERSION_NEUTRAL_ATTACK_PROGRESS_OVERRIDE_MARGIN, 2200)
        if candidateNeutralAttack then
            return candidateHasStrategicNeutralAttack(ai, state, candidateItem.candidate, ctx)
                and candidateProgress >= bestProgress + overrideMargin
        end
        local bestStrategic = candidateHasStrategicNeutralAttack(ai, state, bestItem.candidate, ctx)
        return (not bestStrategic) or candidateProgress >= bestProgress - overrideMargin
    end

    if math.abs(candidateProgress - bestProgress) >= margin then
        return candidateProgress > bestProgress
    end

    return ctx.score.isBetter(candidateScore, bestScore)
end

local function combatItemIsLowValueChip(item)
    local candidate = item and item.candidate or nil
    if not candidate or candidate.hasFactionAttack ~= true then
        return false
    end
    if tostring(candidate.combatClass or "") ~= "low_value_safe_chip" then
        return false
    end
    local combatValue = candidate.combatValue or {}
    if num(combatValue.kills, 0) > 0 or num(combatValue.commandantDamage, 0) > 0 then
        return false
    end
    return true
end

local function earlyLowValueChipSuppressed(item, ctx, contracts)
    if not (ctx and ctx.phase and ctx.phase.early == true) then
        return false
    end
    if contracts and contracts.drawPressureActive == true then
        return false
    end
    return combatItemIsLowValueChip(item)
end

local function progressiveNonCombatBeatsLowValueCombat(ai, state, progressItem, combatItem, ctx, contracts)
    if not (contracts and contracts.conversionActive == true) then
        return false
    end
    if contracts.defenseActive == true or contracts.drawPressureActive == true then
        return false
    end
    if not progressItem or not combatItemIsLowValueChip(combatItem) then
        return false
    end

    local candidate = progressItem.candidate
    if not candidate or candidate.hasFactionAttack == true or candidateHasSkipAction(candidate) then
        return false
    end
    if candidateHasNeutralOnlyAttack(candidate) then
        return false
    end

    local progress = nonCombatProgressValue(ai, state, progressItem, ctx)
    if progress < num(ctx.cfg.CONVERSION_LOW_VALUE_COMBAT_PROGRESS_MIN, 900) then
        return false
    end

    local progressScore = progressItem.finalScore or progressItem.fastScore or {}
    local combatScore = combatItem.finalScore or combatItem.fastScore or {}
    local scoreSlack = num(ctx.cfg.CONVERSION_LOW_VALUE_COMBAT_SCORE_SLACK, 700)
    return num(progressScore.total, 0) >= num(combatScore.total, 0) - scoreSlack
end

local function analyzeFactionAttackSequence(ai, beforeState, candidate, actingPlayer, ctx)
    local summary = {
        factionAttackCount = 0,
        damagingFactionAttackCount = 0,
        zeroDamageFactionAttackCount = 0,
        meleeFactionAttackCount = 0,
        rangedFactionAttackCount = 0,
        totalDamage = 0,
        commandantDamage = 0,
        kills = 0,
        expectedKillValue = 0,
        bestTargetValue = 0,
        attackKind = "none",
        targetName = nil,
        targetPlayer = nil
    }

    local currentState = beforeState
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action and action.type == "attack" and currentState then
            local isFaction = isFactionAttack(ctx, currentState, action, actingPlayer)
            local attacker = getUnitAt(ai, currentState, action.unit and action.unit.row, action.unit and action.unit.col)
            local target = getActionTargetUnit(ai, currentState, action)
            local damage = 0
            local targetHp = num(target and (target.currentHp or target.startingHp), 0)
            local targetValue = 0
            if ai and ai.calculateDamage and attacker and target then
                damage = num(ai:calculateDamage(attacker, target), 0)
            end
            if ai and ai.getUnitBaseValue and target then
                targetValue = num(ai:getUnitBaseValue(target, currentState), 0)
            end

            if isFaction then
                summary.factionAttackCount = summary.factionAttackCount + 1
                summary.totalDamage = summary.totalDamage + damage
                if damage > 0 then
                    summary.damagingFactionAttackCount = summary.damagingFactionAttackCount + 1
                else
                    summary.zeroDamageFactionAttackCount = summary.zeroDamageFactionAttackCount + 1
                end
                summary.bestTargetValue = math.max(summary.bestTargetValue, targetValue)
                summary.targetName = target and target.name or summary.targetName
                summary.targetPlayer = target and target.player or summary.targetPlayer
                local attackKind = getAttackKind(ai, attacker)
                if summary.attackKind == "none" then
                    summary.attackKind = attackKind
                end
                if attackKind == "ranged" then
                    summary.rangedFactionAttackCount = summary.rangedFactionAttackCount + 1
                else
                    summary.meleeFactionAttackCount = summary.meleeFactionAttackCount + 1
                end
                if target and tostring(target.name or "") == "Commandant" and num(target.player, 0) ~= num(actingPlayer, 0) then
                    summary.commandantDamage = summary.commandantDamage + damage
                end
                if targetHp > 0 and damage >= targetHp then
                    summary.kills = summary.kills + 1
                    summary.expectedKillValue = summary.expectedKillValue + targetValue
                end
            end
        end

        if currentState then
            currentState = (ctx and ctx.cache and ctx.cache.simulate)
                and ctx.cache.simulate(ai, currentState, {action}, actingPlayer, ctx)
                or (ai and ai.simulateActionSequenceForPlayer and ai:simulateActionSequenceForPlayer(currentState, {action}, actingPlayer, {}))
        end
    end

    return summary
end

local function classifyCombatCandidate(ai, beforeState, candidate, afterOur, ctx, contracts)
    local info = analyzeFactionAttackSequence(ai, beforeState, candidate, ctx.aiPlayer, ctx)
    local winsNow = afterOur and ctx.evaluator and ctx.evaluator.isCommandantDead
        and ctx.evaluator.isCommandantDead(afterOur, ctx.enemyPlayer) == true
    local allowsImmediateOwnLethal = false
    if afterOur and ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal then
        allowsImmediateOwnLethal = ctx.threatModel.hasImmediateCommandantLethal(
            ai,
            afterOur,
            ctx.enemyPlayer,
            ctx.aiPlayer,
            ctx
        ) == true
    end

    local sanitizerOk = candidate and candidate.sanitizerOk ~= false
    local hasFactionAttack = info.factionAttackCount > 0
    local hasDamagingFactionAttack = info.damagingFactionAttackCount > 0
    local hasZeroDamageFactionAttack = num(info.zeroDamageFactionAttackCount, 0) > 0
    local safe = hasFactionAttack
        and hasDamagingFactionAttack
        and sanitizerOk
        and (winsNow or not allowsImmediateOwnLethal)
    local inDefense = contracts and contracts.defenseActive == true
    local inPressureDefense = inDefense and contracts.defenseKind == "pressure"
    local preventsImmediateLoss = candidate and candidate.tacticalTags and candidate.tacticalTags.preventsImmediateLoss == true
    if inPressureDefense then
        preventsImmediateLoss = candidatePressureDefenseResolved(ai, candidate, afterOur, contracts, ctx)
    elseif inDefense and afterOur and ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal then
        local stillLethal = ctx.threatModel.hasImmediateCommandantLethal(
            ai,
            afterOur,
            ctx.enemyPlayer,
            ctx.aiPlayer,
            ctx
        ) == true
        if not stillLethal then
            preventsImmediateLoss = true
            candidate.tacticalTags = candidate.tacticalTags or {}
            candidate.tacticalTags.preventsImmediateLoss = true
        else
            preventsImmediateLoss = false
            if candidate.tacticalTags then
                candidate.tacticalTags.preventsImmediateLoss = false
            end
        end
    end
    if inDefense and not winsNow and not preventsImmediateLoss then
        -- Under active DEFEND_NOW, combat that does not answer the active threat is unsafe by contract.
        safe = false
    end

    local combatClass = "unsafe_or_losing_attack"
    if hasFactionAttack then
        if winsNow and info.commandantDamage > 0 then
            combatClass = "commandant_kill"
        elseif candidate and candidate.tacticalTags and candidate.tacticalTags.forceWinSetup == true then
            combatClass = "forced_win_setup"
        elseif inDefense and preventsImmediateLoss and safe then
            combatClass = "immediate_defense_attack"
        elseif safe and info.kills > 0 then
            combatClass = "safe_unit_kill"
        elseif safe and info.commandantDamage > 0 then
            combatClass = "safe_commandant_pressure"
        elseif safe and info.bestTargetValue >= num(ctx.cfg.COMBAT_HIGH_VALUE_TARGET_MIN or 65, 65) and info.totalDamage >= 2 then
            combatClass = "safe_high_value_damage"
        elseif safe and contracts and contracts.drawPressureActive == true then
            combatClass = "official_draw_reset_attack"
        elseif safe and info.totalDamage > 0 and info.expectedKillValue >= num(ctx.cfg.COMBAT_SAFE_TRADE_VALUE_MIN or 20, 20) then
            combatClass = "safe_trade"
        elseif safe and info.totalDamage > 0 then
            combatClass = "low_value_safe_chip"
        end
    end

    candidate.combatClass = combatClass
    candidate.combatValue = {
        targetName = info.targetName,
        targetPlayer = info.targetPlayer,
        damage = info.totalDamage,
        damagingFactionAttackCount = info.damagingFactionAttackCount,
        zeroDamageFactionAttackCount = info.zeroDamageFactionAttackCount,
        kills = info.kills,
        targetValue = info.bestTargetValue,
        commandantDamage = info.commandantDamage,
        resetsOfficialDraw = hasFactionAttack and contracts and contracts.drawPressureActive == true
    }
    local safetyReason = "safe"
    if not safe then
        if hasFactionAttack ~= true then
            safetyReason = "not_faction_attack"
        elseif hasDamagingFactionAttack ~= true then
            safetyReason = "zero_damage_faction_attack"
        elseif sanitizerOk ~= true then
            safetyReason = "illegal_after_sanitize"
        elseif allowsImmediateOwnLethal == true and not winsNow then
            safetyReason = "allows_immediate_own_commandant_lethal"
        elseif inDefense and not winsNow and not preventsImmediateLoss then
            safetyReason = "defense_unresolved"
        else
            safetyReason = "unsafe_or_losing_attack"
        end
    end

    candidate.combatSafety = {
        safe = safe == true,
        allowsImmediateOwnLethal = allowsImmediateOwnLethal == true,
        sanitizerOk = sanitizerOk == true,
        replyChecked = false,
        reason = safetyReason
    }
    candidate.tacticalTags = candidate.tacticalTags or {}
    candidate.tacticalTags.zeroDamageFactionAttack = info.zeroDamageFactionAttackCount > 0
    candidate.selectedAttackKind = info.attackKind
end

local function itemHasZeroDamageFactionAttack(ai, state, ctx, item)
    if not ctx then
        return false
    end
    local candidate = item and item.candidate or nil
    if not candidate then
        return false
    end

    local combatValue = candidate.combatValue
    if combatValue and num(combatValue.zeroDamageFactionAttackCount, 0) > 0 then
        return true
    end

    local analysis = analyzeFactionAttackSequence(ai, state, candidate, ctx and ctx.aiPlayer, ctx)
    return num(analysis and analysis.zeroDamageFactionAttackCount, 0) > 0
end

isFactionAttack = function(ctx, state, action, actingPlayer)
    return ctx.evaluator
        and ctx.evaluator.isFactionInteractionAttackAction
        and ctx.evaluator.isFactionInteractionAttackAction(state, action, actingPlayer) == true
end

function M.itemHasOnlyZeroDamageFactionAttacks(ai, state, ctx, item)
    local candidate = item and item.candidate or nil
    local actions = candidate and candidate.actions or nil
    if not (ai and state and ctx and actions and #actions > 0) then
        return false
    end

    local currentState = state
    local sawZeroDamageFactionAttack = false
    for _, action in ipairs(actions) do
        if action and action.type and action.type ~= "skip" then
            if action.type ~= "attack" or not isFactionAttack(ctx, currentState, action, ctx.aiPlayer) then
                return false
            end

            local target = getActionTargetUnit(ai, currentState, action)
            local attacker = getUnitAt(ai, currentState, action.unit and action.unit.row, action.unit and action.unit.col)
            local damage = attacker and target and ai.calculateDamage and num(ai:calculateDamage(attacker, target), 0) or 0
            if damage > 0 then
                return false
            end
            sawZeroDamageFactionAttack = true

            currentState = currentState
                and (
                    (ctx.cache and ctx.cache.simulate)
                        and ctx.cache.simulate(ai, currentState, {action}, ctx.aiPlayer, ctx)
                        or (ai.simulateActionSequenceForPlayer and ai:simulateActionSequenceForPlayer(currentState, {action}, ctx.aiPlayer, {}))
                )
                or nil
        end
    end

    return sawZeroDamageFactionAttack == true
end

local function annotateCandidateDiagnostics(evaluatorModule, beforeState, candidate, aiPlayer)
    local hasFactionAttack = evaluatorModule
        and evaluatorModule.candidateHasFactionInteractionAttack
        and evaluatorModule.candidateHasFactionInteractionAttack(beforeState, candidate, aiPlayer) == true
    local passiveOnly = evaluatorModule
        and evaluatorModule.candidateIsPassiveOnly
        and evaluatorModule.candidateIsPassiveOnly(candidate, beforeState, aiPlayer) == true

    candidate.hasFactionAttack = hasFactionAttack == true
    candidate.passiveOnly = passiveOnly == true
    return candidate
end

local function entryTargetUnit(ai, state, entry)
    local action = entry and entry.action or nil
    if entry and entry.target then
        return entry.target
    end
    return getActionTargetUnit(ai, state, action)
end

local function collectRankedAttackStats(ctx, ranked)
    local count = 0
    local bestAttackFast = nil
    for _, item in ipairs(ranked or {}) do
        if item and item.candidate and item.candidate.hasFactionAttack == true then
            count = count + 1
            if ctx.score.isBetter(item.fastScore, bestAttackFast and bestAttackFast.fastScore or nil) then
                bestAttackFast = item
            end
        end
    end
    ctx.stats.rankedWithFactionAttack = count
    ctx.stats.bestFactionAttackFastScore = bestAttackFast and copyScoreTuple(bestAttackFast.fastScore) or nil
    return bestAttackFast
end

local function itemEarlyIntentBreakdown(item)
    local scoreData = item and (item.fastScore or item.finalScore) or nil
    return scoreData and scoreData.breakdown and scoreData.breakdown.earlyIntent or nil
end

local function earlyBreakdownHasReason(breakdown, reason)
    for _, item in ipairs((breakdown and breakdown.reasons) or {}) do
        if item == reason then
            return true
        end
    end
    return false
end

local function itemConversionBreakdown(item)
    local scoreData = item and (item.fastScore or item.finalScore) or nil
    return scoreData and scoreData.breakdown and scoreData.breakdown.conversion or nil
end

local function tacticalOverrideReasonForItem(ai, ctx, beforeState, item, contracts)
    local candidate = item and item.candidate or nil
    if not candidate then
        return nil
    end

    local tags = candidate.tacticalTags or {}
    local scoreData = item.finalScore or item.fastScore or {}
    if num(scoreData.tier, 0) >= ctx.score.TIER.WIN_NOW or tags.winsNow == true then
        return "win_now"
    end

    if tags.preventsImmediateLoss == true
        or ((contracts and contracts.defenseActive == true) and itemAddressesActiveDefense(ai, item, contracts or {}, ctx)) then
        return "defend_now"
    end

    local unsafe = item.leavesImmediateLethal == true or tags.allowsImmediateLoss == true
    if unsafe then
        return nil
    end

    local conversion = itemConversionBreakdown(item)
    if conversion and conversion.createsNextTurnCommandantLethal == true then
        return "winning_race"
    end
    if tags.forceWinSetup == true then
        return "winning_race"
    end
    if tags.opensCommandantPressure == true then
        return "commandant_pressure_setup"
    end

    local combatValue = candidate.combatValue or {}
    local damage = num(combatValue.damage, 0)
    local kills = num(combatValue.kills, 0)
    local commandantDamage = num(combatValue.commandantDamage, 0)
    if (candidate.hasFactionAttack == true or candidate.containsAttack == true)
        and (damage <= 0 or kills <= 0 or commandantDamage <= 0) then
        local analysis = analyzeFactionAttackSequence(ai, beforeState, candidate, ctx.aiPlayer, ctx)
        damage = math.max(damage, num(analysis.totalDamage, 0))
        kills = math.max(kills, num(analysis.kills, 0))
        commandantDamage = math.max(commandantDamage, num(analysis.commandantDamage, 0))
    end

    local combatClass = tostring(candidate.combatClass or "")
    if kills > 0 or combatClass == "safe_unit_kill" then
        return "safe_kill"
    end
    if commandantDamage > 0 or combatClass == "safe_commandant_pressure" then
        return "commandant_pressure"
    end
    if (contracts and contracts.drawPressureActive == true)
        and (combatValue.resetsOfficialDraw == true or combatClass == "official_draw_reset_attack") then
        return "draw_pressure"
    end
    if not (ctx and ctx.phase and ctx.phase.early == true)
        and damage >= num(ctx.cfg.EARLY_TACTICAL_OVERRIDE_DAMAGE_MIN, 2) then
        return "damage_threshold"
    end

    return nil
end

local function itemHasHardCombatOverride(ai, ctx, beforeState, item, contracts)
    local candidate = item and item.candidate or nil
    if not (candidate and candidate.hasFactionAttack == true) then
        return false
    end
    if tostring(candidate.combatClass or "") == "safe_high_value_damage" then
        return false
    end
    local reason = tacticalOverrideReasonForItem(ai, ctx, beforeState, item, contracts)
    return reason ~= nil and reason ~= "damage_threshold"
end

function M.hardLockReasonForSelection(ai, beforeState, ctx, contracts, item)
    local candidate = item and item.candidate or nil
    if not candidate then
        return nil
    end

    local tags = candidate.tacticalTags or {}
    local scoreData = item.finalScore or item.fastScore or {}
    local winTier = ctx and ctx.score and ctx.score.TIER and ctx.score.TIER.WIN_NOW or 100
    if num(scoreData.tier, 0) >= winTier
        or tags.winsNow == true then
        return "win_now"
    end

    if contracts and contracts.defenseActive == true then
        if M.itemHasOnlyZeroDamageFactionAttacks(ai, beforeState, ctx, item) then
            if ctx and ctx.stats then
                ctx.stats.hardSelectionZeroDamageOnlyRejected =
                    num(ctx.stats.hardSelectionZeroDamageOnlyRejected, 0) + 1
                ctx.stats.hardSelectionZeroDamageOnlyRejectedReason =
                    "zero_damage_only_cannot_prove_defend_now"
            end
            return nil
        end
        if itemAddressesActiveDefense(ai, item, contracts, ctx) then
            return "defend_now"
        end
        return nil
    end

    if candidate.hasFactionAttack == true then
        local reason = tacticalOverrideReasonForItem(ai, ctx, beforeState, item, contracts)
        if reason == "safe_kill" then
            local commitRejected = false
            if earlyAttackCommitmentRejects then
                commitRejected = earlyAttackCommitmentRejects(ai, beforeState, ctx, contracts, item) == true
            end
            if commitRejected then
                return nil
            end
            return "safe_kill"
        end
    end

    return nil
end

function M.earlyPositionTargetText(target)
    if not target then
        return nil
    end
    local role = target.frontierRole and (":" .. tostring(target.frontierRole)) or ""
    return string.format(
        "%s,%s:%s:%.0f",
        tostring(target.row or "?"),
        tostring(target.col or "?"),
        tostring(target.status or "unknown"),
        num(target.value, 0)
    ) .. role
end

function M.coreTimeoutBestAllowed(ai, beforeState, ctx, contracts, item)
    local candidate = item and item.candidate or nil
    if not candidate then
        return false, "missing_candidate"
    end

    local tags = candidate.tacticalTags or {}
    local scoreData = item.finalScore or item.fastScore or {}
    local winTier = ctx and ctx.score and ctx.score.TIER and ctx.score.TIER.WIN_NOW or 100
    local winsNow = num(scoreData.tier, 0) >= winTier or tags.winsNow == true
    local safetyReason = tostring(candidate.combatSafety and candidate.combatSafety.reason or "none")
    if candidate.hasFactionAttack == true
        and safetyReason == "allows_immediate_own_commandant_lethal"
        and not winsNow then
        return false, "unsafe_own_commandant_lethal"
    end

    if contracts and contracts.defenseActive == true then
        local hardReason = M.hardLockReasonForSelection(ai, beforeState, ctx, contracts, item)
        if hardReason == "win_now" or hardReason == "defend_now" then
            return true
        end
        return false, "does_not_satisfy_defend_now"
    end

    return true
end

local function markSelectedDiagnostics(ai, ctx, beforeState, selected)
    local candidate = selected and selected.candidate or {}
    local selectedFast = selected and selected.fastScore or nil
    local selectedFinal = selected and selected.finalScore or nil
    local tags = candidate and candidate.tacticalTags or {}
    local target = tags.earlyPositionTarget
    ctx.stats.selectedPassiveOnly = candidate and candidate.passiveOnly == true
    ctx.stats.selectedFastScore = selectedFast and copyScoreTuple(selectedFast) or nil
    ctx.stats.selectedFinalScore = selectedFinal and copyScoreTuple(selectedFinal) or nil
    ctx.stats.selectedScoreDelta = num(selectedFinal and selectedFinal.total, 0)
        - num(selectedFast and selectedFast.total, 0)
    ctx.stats.selectedCandidateSource = candidate and candidate.source or nil
    ctx.stats.selectedCandidateLane = selected and selected.lane or nil
    ctx.stats.selectedRequiredLane = selected and selected.requiredLane == true
    ctx.stats.selectedEarlyPositionReason = tags.earlyPositionReason
    ctx.stats.selectedEarlyPositionTarget = M.earlyPositionTargetText(target)
    ctx.stats.selectedSoftDefensePressure = tags.softDefensePressure == true
    ctx.stats.selectedSoftDefensePressureReason = tags.softDefensePressureReason
    ctx.stats.selectedSoftDefensePressureBeforeDamage = finiteNumberOrNil(tags.softDefensePressureBeforeDamage)
    ctx.stats.selectedSoftDefensePressureAfterDamage = finiteNumberOrNil(tags.softDefensePressureAfterDamage)
    ctx.stats.selectedSoftDefensePressureBeforeAttackers = finiteNumberOrNil(tags.softDefensePressureBeforeAttackers)
    ctx.stats.selectedSoftDefensePressureAfterAttackers = finiteNumberOrNil(tags.softDefensePressureAfterAttackers)
    ctx.stats.selectedSoftDefensePressureReduced = tags.softDefensePressureReduced == true
    ctx.stats.selectedSoftDefensePressureCleared = tags.softDefensePressureCleared == true
    ctx.stats.selectedSoftDefensePressureNet = finiteNumberOrNil(tags.softDefensePressureNet)
    ctx.stats.selectedContainsDeploy = candidate and candidate.containsDeploy == true
    ctx.stats.selectedContainsAttack = candidate and candidate.containsAttack == true
    ctx.stats.selectedReplyQuestion = selected and selected.reply and selected.reply.question or nil
    ctx.stats.selectedReplyOutcome = M.replyOutcomeKey(selected and selected.reply or nil)
    ctx.stats.selectedExtensionQuestion = selected and selected.extension and selected.extension.question or nil
    ctx.stats.selectedExtensionOutcome = M.extensionOutcomeKey(selected and selected.extension or nil)
    ctx.stats.selectedMatchesBestSoFar = candidate
        and candidate.signature
        and candidate.signature == ctx.stats.bestSoFarSignature
        or false
    local earlyBreakdown = itemEarlyIntentBreakdown(selected)
    if earlyBreakdown then
        ctx.stats.earlyFormationScore = num(earlyBreakdown.value, 0)
        ctx.stats.earlyFormationReasons = copyArray(earlyBreakdown.reasons or {})
    end
    ctx.stats.tacticalOverrideReason = tacticalOverrideReasonForItem(ai, ctx, beforeState, selected, ctx.activeContracts or {})

    local analysis = analyzeFactionAttackSequence(ai, beforeState, candidate, ctx.aiPlayer, ctx)
    ctx.stats.selectedFactionAttackCount = num(analysis.factionAttackCount, 0)
    ctx.stats.selectedDamagingFactionAttackCount = num(analysis.damagingFactionAttackCount, 0)
    ctx.stats.selectedZeroDamageFactionAttackCount = num(analysis.zeroDamageFactionAttackCount, 0)
    ctx.stats.selectedMeleeFactionAttackCount = num(analysis.meleeFactionAttackCount, 0)
    ctx.stats.selectedRangedFactionAttackCount = num(analysis.rangedFactionAttackCount, 0)
    ctx.stats.selectedCommandantDamage = num(analysis.commandantDamage, 0)
    ctx.stats.selectedKillCount = num(analysis.kills, 0)
    ctx.stats.selectedHasFactionAttack = (candidate and candidate.hasFactionAttack == true)
        or ctx.stats.selectedFactionAttackCount > 0
    ctx.stats.selectedCombatClass = ctx.stats.selectedHasFactionAttack
        and candidate
        and candidate.combatClass
        or nil
    ctx.stats.selectedCombatSafetyReason = candidate
        and candidate.combatSafety
        and candidate.combatSafety.reason
        or nil
    if ctx.stats.combatContractActive == true and ctx.stats.selectedFactionAttackCount > 0 then
        ctx.stats.combatSelected = math.max(num(ctx.stats.combatSelected, 0), 1)
    end

    local conversion = selectedFast
        and selectedFast.breakdown
        and selectedFast.breakdown.conversion
        or nil
    ctx.stats.drawConversionOpportunity = conversion and conversion.opportunity == true or false
    ctx.stats.drawConversionChosen = conversion and conversion.chosen == true or false
    ctx.stats.drawConversionMissReason = conversion and conversion.missReason or nil
    ctx.stats.selectedCreatesNextTurnCommandantLethal = conversion and conversion.createsNextTurnCommandantLethal == true or false
    ctx.stats.selectedRemovesEnemyLastAttacker = conversion and conversion.removesEnemyLastAttacker == true or false

    ctx.stats.defenseRaceProof = tags.defenseRaceProof or tags.pressureDefenseProof or nil
    ctx.stats.defenseRaceBestETA = finiteNumberOrNil(tags.defenseRaceBestETA)
        or finiteNumberOrNil(tags.threatRemovalSetupEta)
        or ctx.stats.defenseRaceBestETA
    ctx.stats.defenseRaceLineBlock = tags.defenseRaceLineBlock == true
        or tags.blocksThreatLine == true
        or false
end

local function computeAttackLossReason(ctx, best, bestAttackFast, bestAttackFinal)
    if not best or (best.candidate and best.candidate.hasFactionAttack == true) then
        return nil
    end
    if num(ctx.stats.legalAttackActions, 0) <= 0 then
        return "no_legal_faction_attack"
    end
    if num(ctx.stats.legalAttackActions, 0) > 0 and num(ctx.stats.combatDirectGenerated, 0) <= 0 then
        return "combat_lane_generation_failed"
    end
    if num(ctx.stats.candidateWithFactionAttack, 0) <= 0 then
        return "no_candidate_with_faction_attack"
    end
    if num(ctx.stats.combatGeneratedTotal, 0) > 0 and num(ctx.stats.combatRanked, 0) <= 0 then
        if num(ctx.stats.combatExplicitSanitizeAttempts, 0) >= num(ctx.stats.combatGeneratedTotal, 0)
            and num(ctx.stats.combatExplicitSanitizeRejected, 0) >= num(ctx.stats.combatGeneratedTotal, 0) then
            return "all_combat_illegal_after_explicit_sanitize"
        end
        if ctx.stats.timeout == true then
            return "combat_cut_before_rank_due_budget"
        end
        return "faction_attack_filtered_before_rank"
    end
    if num(ctx.stats.combatRanked, 0) > 0 and num(ctx.stats.combatSafeRanked, 0) <= 0 then
        return "all_combat_unsafe_or_losing"
    end
    if num(ctx.stats.combatRanked, 0) > 0 and num(ctx.stats.combatFinalists, 0) <= 0 then
        return "combat_cut_before_finalist"
    end
    if num(ctx.stats.rankedWithFactionAttack, 0) <= 0 then
        return "faction_attack_filtered_before_rank"
    end
    if num(ctx.stats.finalistWithFactionAttack, 0) <= 0 then
        return "faction_attack_cut_before_finalists"
    end
    if num(ctx.stats.combatSkippedWithProof, 0) > 0 then
        return "combat_skipped_with_proof_" .. tostring(ctx.stats.passiveOverrideReason or "unknown")
    end
    if num(ctx.stats.combatSkippedWithoutProof, 0) > 0 then
        return "combat_skipped_without_proof"
    end
    if bestAttackFinal then
        return "best_attack_lost_final_score"
    end
    if bestAttackFast then
        if ctx.stats.timeout == true then
            return "timeout_before_attack_conversion"
        end
        return "best_attack_lost_fast_score"
    end
    return "unknown"
end

local function candidateContainsSkip(candidate)
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action and action.type == "skip" then
            return true
        end
    end
    return false
end

local function countLegalFactionAttackActions(ai, state, playerId, evaluatorModule, ctx)
    if not ai or not state or not playerId or not ai.collectLegalActions then
        return 0
    end

    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local legalEntries = ai:collectLegalActions(state, {
        aiPlayer = playerId,
        includeMove = false,
        includeAttack = true,
        includeRepair = false,
        includeDeploy = false,
        allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    }) or {}

    local count = 0
    for _, entry in ipairs(legalEntries) do
        local action = entry and entry.action or nil
        if isFactionAttack({evaluator = evaluatorModule}, state, action, playerId) then
            local simulatable = nil
            if action then
                simulatable = ctx
                    and ctx.cache
                    and ctx.cache.simulate
                    and ctx.cache.simulate(ai, state, {action}, playerId, ctx)
                    or ai:simulateActionSequenceForPlayer(state, {action}, playerId, {})
            end
            if simulatable then
                count = count + 1
            end
        end
        if ctx and ctx.shouldStop and ctx.shouldStop() then
            break
        end
    end

    return count
end

local function countLegalMoveAttackFactionAttacks(ai, state, playerId, ctx)
    if not ai or not state or not playerId then
        return 0
    end

    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local moves = ai:collectLegalActions(state, {
        includeMove = true,
        includeAttack = false,
        includeRepair = false,
        includeDeploy = false,
        aiPlayer = playerId,
        allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    }) or {}

    local count = 0
    local moveScanLimit = clampLimit((ctx.cfg.COMBAT_MOVE_ATTACK_CAP or 12) * 2, 4, 48)
    for index = 1, math.min(#moves, moveScanLimit) do
        if ctx.shouldStop and ctx.shouldStop() then
            break
        end

        local moveAction = moves[index] and moves[index].action or nil
        if moveAction then
            local afterMove = ctx.cache.simulate(ai, state, {moveAction}, playerId, ctx)
            if afterMove then
                local followups = ai:collectLegalActions(afterMove, {
                    includeMove = false,
                    includeAttack = true,
                    includeRepair = false,
                    includeDeploy = false,
                    aiPlayer = playerId,
                    allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
                }) or {}

                local followupScanLimit = clampLimit((ctx.cfg.COMBAT_MOVE_ATTACK_CAP or 12) * 2, 4, 64)
                for followupIndex = 1, math.min(#followups, followupScanLimit) do
                    if ctx.shouldStop and ctx.shouldStop() then
                        break
                    end
                    local entry = followups[followupIndex]
                    local attackAction = entry and entry.action or nil
                    if isFactionAttack(ctx, afterMove, attackAction, playerId) then
                        count = count + 1
                        break
                    end
                end
            end
        end
    end

    return count
end

local function countLegalMoveAttackThreatAttacks(ai, state, ctx, threat)
    if not (ai and state and ctx and ctx.aiPlayer and threatHasImmediateDanger(threat)) then
        return 0
    end

    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local moves = ai:collectLegalActions(state, {
        includeMove = true,
        includeAttack = false,
        includeRepair = false,
        includeDeploy = false,
        aiPlayer = ctx.aiPlayer,
        allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    }) or {}

    local count = 0
    local moveScanLimit = clampLimit((ctx.cfg.COMBAT_MOVE_ATTACK_CAP or 12) * 2, 4, 48)
    for index = 1, math.min(#moves, moveScanLimit) do
        if ctx.shouldStop and ctx.shouldStop() then
            break
        end

        local moveAction = moves[index] and moves[index].action or nil
        if moveAction then
            local afterMove = ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, {moveAction}, ctx.aiPlayer, ctx)
            if afterMove then
                local followups = ai:collectLegalActions(afterMove, {
                    includeMove = false,
                    includeAttack = true,
                    includeRepair = false,
                    includeDeploy = false,
                    aiPlayer = ctx.aiPlayer,
                    allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
                }) or {}

                local followupScanLimit = clampLimit((ctx.cfg.COMBAT_MOVE_ATTACK_CAP or 12) * 2, 4, 64)
                for followupIndex = 1, math.min(#followups, followupScanLimit) do
                    if ctx.shouldStop and ctx.shouldStop() then
                        break
                    end
                    local attackAction = followups[followupIndex] and followups[followupIndex].action or nil
                    if actionTargetsThreatUnit(attackAction, threat)
                        and isFactionAttack(ctx, afterMove, attackAction, ctx.aiPlayer) then
                        local attacker = getUnitAt(ai, afterMove, attackAction.unit and attackAction.unit.row, attackAction.unit and attackAction.unit.col)
                        local target = getActionTargetUnit(ai, afterMove, attackAction)
                        local damage = 0
                        if attacker and target and ai.calculateDamage then
                            damage = num(ai:calculateDamage(attacker, target), 0)
                        end
                        if damage > 0 then
                            count = count + 1
                            break
                        end
                    end
                end
            end
        end
    end

    return count
end

local function newLane(name, contract, requiredFinalistSlots, minimumRanked, proofRequiredToSkip)
    return {
        name = name,
        contract = contract,
        requiredFinalistSlots = requiredFinalistSlots or 0,
        minimumRanked = minimumRanked or 0,
        proofRequiredToSkip = proofRequiredToSkip == true,
        candidates = {}
    }
end

local function ensureLane(lanesByName, laneName, contract, defaults)
    if lanesByName[laneName] then
        return lanesByName[laneName]
    end

    local lane = newLane(
        laneName,
        contract,
        defaults and defaults.requiredFinalistSlots or 0,
        defaults and defaults.minimumRanked or 0,
        defaults and defaults.proofRequiredToSkip or false
    )
    lanesByName[laneName] = lane
    return lane
end

local function buildCandidate(ctx, actions, opts)
    local options = opts or {}
    local candidate = {
        actions = copyArray(actions or {}),
        signature = ctx.turnEnumerator.sequenceSignature(actions or {}),
        source = options.source or "contract_lane",
        buckets = copyArray(options.buckets or {}),
        tacticalTags = copyMap(options.tacticalTags or {}),
        containsDeploy = false,
        containsAttack = false,
        completeTurn = options.completeTurn ~= false,
        terminal = options.terminal == true,
        legalSkipReason = options.legalSkipReason,
        contract = options.contract
    }

    for _, action in ipairs(candidate.actions) do
        if action and action.type == "supply_deploy" then
            candidate.containsDeploy = true
        elseif action and action.type == "attack" then
            candidate.containsAttack = true
        end
    end

    return candidate
end

function M._hardPrefixFillerRejected(ai, beforeState, prefixState, action, afterState, ctx, options)
    if not (ai and beforeState and prefixState and action and action.type and action.type ~= "skip") then
        return false, nil
    end

    local rejectReason = nil
    if action.type == "move" and action.target then
        local mover = getUnitAt(ai, prefixState, action.unit and action.unit.row, action.unit and action.unit.col)
        if mover
            and ai.isSuicidalMovement
            and ai:isSuicidalMovement(prefixState, {row = action.target.row, col = action.target.col}, mover) then
            rejectReason = "unsafe_move_attack_exposure"
        end
    end

    if not rejectReason
        and afterState
        and not (options and options.avoidOpeningCommandantPressure == false) then
        local fillerCandidate = buildCandidate(ctx, {action}, {
            source = "hard_prefix_filler_check",
            buckets = {"hard_prefix_filler"}
        })
        if candidateOpensCommandantPressure(ai, prefixState, afterState, fillerCandidate, ctx) then
            rejectReason = "opens_commandant_pressure"
        end
    end

    if rejectReason then
        if ctx and ctx.stats then
            ctx.stats.hardPrefixFillerRejected = num(ctx.stats.hardPrefixFillerRejected, 0) + 1
            ctx.stats.hardPrefixFillerRejectedReason = rejectReason
            ctx.stats.hardPrefixFillerRejectedAction = actionSignature(ctx, action)
        end
        return true, rejectReason
    end

    return false, nil
end

local function chooseContinuationAction(ai, stateAfterFirst, playerId, ctx)
    local entries = ctx.turnEnumerator.collectTournamentActions(ai, stateAfterFirst, playerId, ctx, {
        includeMove = true,
        includeAttack = true,
        includeRepair = true,
        includeDeploy = true
    }) or {}

    local ranked = ctx.candidateBuckets.rankAndSelect(ai, stateAfterFirst, entries, playerId, ctx, {
        maxTotal = clampLimit(ctx.cfg.MAX_SECOND_ACTIONS or 36, 4, 64),
        scanLimit = clampLimit((ctx.cfg.MAX_SECOND_ACTIONS or 36) * 2, 8, 96),
        stage = "second"
    })

    return ranked, entries
end

local function buildCandidateFromFirstAction(ai, state, playerId, ctx, firstAction, opts)
    if not firstAction then
        return nil, nil
    end

    local firstState = ctx.cache.simulate(ai, state, {firstAction}, playerId, ctx)
    if not firstState then
        return nil, nil
    end

    local options = opts or {}
    local requiredActions = num(ctx.maxActions, 2)
    local enemyPlayer = ctx.enemyPlayer
    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local avoidOpeningCommandantPressure = tostring(options.contract or "") ~= CONTRACTS.DEFEND_NOW

    if ctx.evaluator.isCommandantDead(firstState, enemyPlayer) then
        local candidate = buildCandidate(ctx, {firstAction}, {
            source = options.source,
            buckets = options.buckets,
            tacticalTags = options.tacticalTags,
            terminal = true,
            legalSkipReason = "terminal_win",
            contract = options.contract
        })
        return candidate, firstState
    end

    if requiredActions <= 1 then
        local candidate = buildCandidate(ctx, {firstAction}, {
            source = options.source,
            buckets = options.buckets,
            tacticalTags = options.tacticalTags,
            contract = options.contract
        })
        return candidate, firstState
    end

    local secondRanked, secondEntries = chooseContinuationAction(ai, firstState, playerId, ctx)

    for _, entry in ipairs(secondRanked or {}) do
        if ctx.shouldStop and ctx.shouldStop() then
            break
        end
        if ctx.hardStop and ctx.hardStop() then
            break
        end
        local secondAction = entry and entry.action or nil
        if secondAction and not (firstAction.type == "supply_deploy" and secondAction.type == "supply_deploy") then
            local fullState = ctx.cache.simulate(ai, state, {firstAction, secondAction}, playerId, ctx)
            if fullState then
                local candidate = buildCandidate(ctx, {firstAction, secondAction}, {
                    source = options.source,
                    buckets = options.buckets,
                    tacticalTags = options.tacticalTags,
                    contract = options.contract
                })
                local unsafeFiller = options.avoidUnsafeFiller == true
                    and M._hardPrefixFillerRejected(ai, state, firstState, secondAction, fullState, ctx, {
                        avoidOpeningCommandantPressure = true
                    })
                    or false
                if not unsafeFiller
                    and not (avoidOpeningCommandantPressure and candidateOpensCommandantPressure(ai, state, fullState, candidate, ctx)) then
                    return candidate, fullState
                end
            end

            if ai and ai.sanitizeActionSequenceForState then
                local sanitized, sanitizeSummary = ai:sanitizeActionSequenceForState(state, {firstAction, secondAction}, {
                    aiPlayer = playerId,
                    maxActions = requiredActions,
                    allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
                })
                local sanitizerRepaired = num(sanitizeSummary and sanitizeSummary.replacements, 0) > 0
                if options.avoidUnsafeFiller == true and sanitizerRepaired then
                    if ctx and ctx.stats then
                        ctx.stats.hardPrefixSanitizerRepairRejected =
                            num(ctx.stats.hardPrefixSanitizerRepairRejected, 0) + 1
                    end
                elseif sanitized and #sanitized > 0 then
                    local repairedState = ctx.cache.simulate(ai, state, sanitized, playerId, ctx)
                    if repairedState then
                        local candidate = buildCandidate(ctx, sanitized, {
                            source = options.source,
                            buckets = options.buckets,
                            tacticalTags = options.tacticalTags,
                            contract = options.contract
                        })
                        local fillerAction = sanitized[2] or secondAction
                        local unsafeFiller = options.avoidUnsafeFiller == true
                            and M._hardPrefixFillerRejected(ai, state, firstState, fillerAction, repairedState, ctx, {
                                avoidOpeningCommandantPressure = true
                            })
                            or false
                        if not unsafeFiller
                            and not (avoidOpeningCommandantPressure and candidateOpensCommandantPressure(ai, state, repairedState, candidate, ctx)) then
                            return candidate, repairedState
                        end
                    end
                end
            end
        end
    end

    local candidate = buildCandidate(ctx, {firstAction}, {
        source = options.source,
        buckets = options.buckets,
        tacticalTags = options.tacticalTags,
        legalSkipReason = (#(secondEntries or {}) == 0) and "no_legal_continuation" or "unsafe_continuations_open_commandant_pressure",
        contract = options.contract
    })
    if not (avoidOpeningCommandantPressure and candidateOpensCommandantPressure(ai, state, firstState, candidate, ctx)) then
        return candidate, firstState
    end

    return nil, nil
end

local function countLegalDirectThreatAttacks(ai, state, ctx, threat)
    if not (ai and state and ctx and ai.collectLegalActions and threatHasImmediateDanger(threat)) then
        return 0
    end

    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local entries = ai:collectLegalActions(state, {
        aiPlayer = ctx.aiPlayer,
        includeMove = false,
        includeAttack = true,
        includeRepair = false,
        includeDeploy = false,
        allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    }) or {}

    local count = 0
    for _, entry in ipairs(entries) do
        local action = entry and entry.action or nil
        if actionTargetsThreatUnit(action, threat) and isFactionAttack(ctx, state, action, ctx.aiPlayer) then
            local attacker = getUnitAt(ai, state, action.unit and action.unit.row, action.unit and action.unit.col)
            local target = getActionTargetUnit(ai, state, action)
            local damage = 0
            if attacker and target and ai.calculateDamage then
                damage = num(ai:calculateDamage(attacker, target), 0)
            end
            local after = damage > 0 and ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, {action}, ctx.aiPlayer, ctx)
            if damage > 0 and after then
                count = count + 1
            end
        end
    end
    return count
end

local function countLegalDirectThreatReductionActions(ai, state, ctx, threat)
    if not (ai and state and ctx and ai.collectLegalActions and threatHasImmediateDanger(threat)) then
        return 0
    end

    local beforeProjected = threatProjectedDamage(threat)
    local beforeCount = threatAttackerCount(threat)
    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local entries = ai:collectLegalActions(state, {
        aiPlayer = ctx.aiPlayer,
        includeMove = false,
        includeAttack = true,
        includeRepair = false,
        includeDeploy = false,
        allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    }) or {}

    local count = 0
    for _, entry in ipairs(entries) do
        local action = entry and entry.action or nil
        if actionTargetsThreatUnit(action, threat) and isFactionAttack(ctx, state, action, ctx.aiPlayer) then
            local afterState = ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, {action}, ctx.aiPlayer, ctx)
            if afterState and ctx.cache and ctx.cache.threat then
                local afterThreat = ctx.cache.threat(ai, afterState, ctx.aiPlayer, ctx.enemyPlayer, ctx)
                local afterProjected = threatProjectedDamage(afterThreat)
                local afterCount = threatAttackerCount(afterThreat)
                if afterProjected <= 0 or afterProjected < beforeProjected or afterCount < beforeCount then
                    count = count + 1
                end
            end
        end
    end

    return count
end

local function detectActiveContracts(ai, state, ctx, baseThreat, drawUrgency, legalAttackActions, legalMoveAttackActions)
    local active = {}
    local defenseThreat = threatPayload(baseThreat)
    local defenseLethal = baseThreat and baseThreat.immediateLethal == true
    local directThreatAttackActions = countLegalDirectThreatAttacks(ai, state, ctx, defenseThreat)
    local directThreatReductionActions = countLegalDirectThreatReductionActions(ai, state, ctx, defenseThreat)
    local moveThreatAttackActions = countLegalMoveAttackThreatAttacks(ai, state, ctx, defenseThreat)
    local defensePressure = (not defenseLethal)
        and threatHasImmediateDanger(baseThreat)
        and threatProjectedDamage(baseThreat) >= num(ctx and ctx.cfg and ctx.cfg.COMMANDANT_PRESSURE_DEFENSE_MIN_PROJECTED_DAMAGE, 1)
    local defenseActive = defenseLethal or defensePressure
    local defenseRaceTTD = estimateThreatTurnsToDeath(state, ctx and ctx.aiPlayer, baseThreat)
    local defenseRaceTTW = nil
    if defenseActive then
        defenseRaceTTW = select(1, estimateOffenseTimeToWin(ai, state, ctx.aiPlayer, ctx.enemyPlayer, ctx, {
            horizonTurns = clampLimit((ctx and ctx.cfg and ctx.cfg.DEFENSE_RACE_TTW_HORIZON_TURNS) or 4, 1, 6)
        }))
    end
    local defenseRaceWinRaceEstimate = defenseActive
        and defensePressure
        and finiteNumberOrNil(defenseRaceTTW) ~= nil
        and finiteNumberOrNil(defenseRaceTTD) ~= nil
        and num(defenseRaceTTW, 99) <= num(defenseRaceTTD, -1)
    local combatActive = (legalAttackActions > 0) or (legalMoveAttackActions > 0) or (drawUrgency and drawUrgency.active == true)
    local conversion = {
        convertWinningPosition = false,
        breakDrawClock = false,
        forceCommandantPressure = false,
        eliminateLowHpUnit = false
    }
    local conversionFeatures = {
        materialDiff = 0,
        ownUnitCount = 0,
        enemyUnitCount = 0,
        ownHubHp = 0,
        enemyHubHp = 0,
        commandantPressure = 0
    }

    local featureSnapshot = nil
    if ctx and ctx.cache and ctx.cache.features then
        featureSnapshot = ctx.cache.features(ai, state, ctx.aiPlayer, ctx)
    elseif ctx and ctx.evaluator and ctx.evaluator.buildStateFeatures then
        featureSnapshot = ctx.evaluator.buildStateFeatures(ai, state, ctx.aiPlayer, ctx)
    end
    if featureSnapshot then
        conversionFeatures.materialDiff = num(featureSnapshot.materialDiff, 0)
        conversionFeatures.ownUnitCount = num(featureSnapshot.ownUnitCount, 0)
        conversionFeatures.enemyUnitCount = num(featureSnapshot.enemyUnitCount, 0)
        conversionFeatures.ownHubHp = num(featureSnapshot.ownHubHp, 0)
        conversionFeatures.enemyHubHp = num(featureSnapshot.enemyHubHp, 0)
        conversionFeatures.commandantPressure = num(featureSnapshot.commandantPressure, 0)
    end

    if not defenseActive then
        local materialAdvThreshold = num(ctx and ctx.cfg and ctx.cfg.CONVERSION_MATERIAL_ADV_MIN, 50)
        local unitAdvThreshold = num(ctx and ctx.cfg and ctx.cfg.CONVERSION_UNIT_ADV_MIN, 1)
        local drawBreakStreak = num(ctx and ctx.cfg and ctx.cfg.CONVERSION_DRAW_STREAK_MIN, 2)
        local drawEarlyStreak = num(ctx and ctx.cfg and ctx.cfg.CONVERSION_DRAW_STREAK_EARLY_MIN, math.max(1, drawBreakStreak - 1))
        local enemyHubHpPressureMax = num(ctx and ctx.cfg and ctx.cfg.CONVERSION_ENEMY_HUB_HP_MAX, 8)
        local commandantPressureMin = num(ctx and ctx.cfg and ctx.cfg.CONVERSION_COMMANDANT_PRESSURE_MIN, 220)
        local lowEnemyUnitCountMax = num(ctx and ctx.cfg and ctx.cfg.CONVERSION_LOW_UNIT_COUNT_MAX, 2)
        local lastEnemyUnitMax = num(ctx and ctx.cfg and ctx.cfg.CONVERSION_LAST_ENEMY_UNIT_MAX, lowEnemyUnitCountMax)

        local materialDiff = num(conversionFeatures.materialDiff, 0)
        local unitDiff = num(conversionFeatures.ownUnitCount, 0) - num(conversionFeatures.enemyUnitCount, 0)
        local drawStreak = num(drawUrgency and drawUrgency.streak, 0)
        local drawPressure = drawUrgency and drawUrgency.active == true
        local drawUrgencyValue = num(drawUrgency and drawUrgency.urgency, 0)
        local enemyHubHp = num(conversionFeatures.enemyHubHp, 0)
        local commandantPressure = num(conversionFeatures.commandantPressure, 0)
        local enemyUnits = num(conversionFeatures.enemyUnitCount, 0)

        conversion.convertWinningPosition = materialDiff >= materialAdvThreshold or unitDiff >= unitAdvThreshold
        conversion.breakDrawClock = drawPressure and (
            drawStreak >= drawBreakStreak
            or drawUrgencyValue > 0
            or (drawStreak >= drawEarlyStreak and combatActive)
        )
        conversion.forceCommandantPressure = enemyHubHp > 0
            and (
                enemyHubHp <= enemyHubHpPressureMax
                or commandantPressure >= commandantPressureMin
                or (combatActive and conversion.convertWinningPosition)
                or (combatActive and conversion.breakDrawClock)
                or (combatActive and enemyUnits <= (lowEnemyUnitCountMax + 1))
                or (drawPressure and drawStreak >= drawEarlyStreak and combatActive)
            )
        conversion.eliminateLowHpUnit = combatActive and (
            enemyUnits <= lowEnemyUnitCountMax
            or enemyUnits <= lastEnemyUnitMax
            or (drawPressure and drawStreak >= drawEarlyStreak and enemyUnits <= (lastEnemyUnitMax + 1))
        )
    end

    if defenseActive then
        active[#active + 1] = CONTRACTS.DEFEND_NOW
    end
    if combatActive then
        active[#active + 1] = CONTRACTS.COMBAT_OR_DRAW_RESET
    end
    if conversion.convertWinningPosition then
        active[#active + 1] = CONTRACTS.CONVERT_WINNING_POSITION
    end
    if conversion.breakDrawClock then
        active[#active + 1] = CONTRACTS.BREAK_DRAW_CLOCK
    end
    if conversion.forceCommandantPressure then
        active[#active + 1] = CONTRACTS.FORCE_COMMANDANT_PRESSURE
    end
    if conversion.eliminateLowHpUnit then
        active[#active + 1] = CONTRACTS.ELIMINATE_LOW_HP_UNIT
    end
    active[#active + 1] = CONTRACTS.CONVERT_ADVANTAGE
    active[#active + 1] = CONTRACTS.BUILD_POSITION

    local evidence = {
        activeContracts = copyArray(active),
        legalDirectFactionAttacks = legalAttackActions,
        legalMoveAttackFactionAttacks = legalMoveAttackActions,
        officialDrawStreak = num(drawUrgency and drawUrgency.streak, 0),
        drawPressureActive = drawUrgency and drawUrgency.active == true,
        drawPressureUrgency = num(drawUrgency and drawUrgency.urgency, 0),
        conversionSignals = copyMap(conversion),
        conversionFeatures = copyMap(conversionFeatures),
        selectedProofReason = nil,
        passiveOverride = nil,
        ownCommandantImmediateDanger = defensePressure == true,
        ownCommandantImmediateLethal = defenseLethal == true,
        ownCommandantProjectedDamage = threatProjectedDamage(baseThreat),
        directThreatAttackActions = directThreatAttackActions,
        directThreatReductionActions = directThreatReductionActions,
        moveThreatAttackActions = moveThreatAttackActions,
        defenseRaceTTD = finiteNumberOrNil(defenseRaceTTD),
        defenseRaceTTW = finiteNumberOrNil(defenseRaceTTW),
        defenseRaceWinRaceEstimate = defenseRaceWinRaceEstimate == true
    }

    return {
        activeNames = active,
        defenseActive = defenseActive,
        defenseKind = defenseLethal and "lethal" or (defensePressure and "pressure" or "none"),
        defenseThreat = defenseThreat,
        directThreatAttackActions = directThreatAttackActions,
        directThreatReductionActions = directThreatReductionActions,
        moveThreatAttackActions = moveThreatAttackActions,
        defenseRaceTTD = finiteNumberOrNil(defenseRaceTTD),
        defenseRaceTTW = finiteNumberOrNil(defenseRaceTTW),
        defenseRaceWinRaceEstimate = defenseRaceWinRaceEstimate == true,
        defenseRaceWinRaceConfirmed = false,
        combatActive = combatActive,
        drawPressureActive = drawUrgency and drawUrgency.active == true,
        convertWinningPosition = conversion.convertWinningPosition == true,
        breakDrawClock = conversion.breakDrawClock == true,
        forceCommandantPressure = conversion.forceCommandantPressure == true,
        eliminateLowHpUnit = conversion.eliminateLowHpUnit == true,
        conversionActive = conversion.convertWinningPosition == true
            or conversion.breakDrawClock == true
            or conversion.forceCommandantPressure == true
            or conversion.eliminateLowHpUnit == true,
        conversionFeatures = conversionFeatures,
        evidence = evidence
    }
end

local function captureAttackActionInfo(ai, state, action)
    if not action or action.type ~= "attack" then
        return nil
    end

    local attacker = getUnitAt(ai, state, action.unit and action.unit.row, action.unit and action.unit.col)
    local target = getActionTargetUnit(ai, state, action)
    local damage = 0
    if ai and ai.calculateDamage and attacker and target then
        damage = num(ai:calculateDamage(attacker, target), 0)
    end
    local targetHp = num(target and (target.currentHp or target.startingHp), 0)

    return {
        attacker = attacker,
        target = target,
        damage = damage,
        targetHp = targetHp,
        kills = targetHp > 0 and damage >= targetHp,
        targetIsCommandant = target and tostring(target.name or "") == "Commandant"
    }
end

local function shouldCountAsSafeTrade(ai, afterOur, ctx)
    if not afterOur or not ctx.threatModel or not ctx.threatModel.hasImmediateCommandantLethal then
        return false
    end

    local enemyLethal = ctx.threatModel.hasImmediateCommandantLethal(
        ai,
        afterOur,
        ctx.enemyPlayer,
        ctx.aiPlayer,
        ctx
    ) == true

    return not enemyLethal
end

local function addLaneCandidate(lane, candidate)
    lane.candidates[#lane.candidates + 1] = candidate
end

local function tournamentActionCount(ai)
    local turnCfg = (((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).TURN or {}
    return clampLimit(turnCfg.ACTIONS_PER_TURN or 2, 1, 3)
end

local function actionDefensePriority(action, threatResult)
    if not action then
        return 0
    end
    local priority = 0
    if actionTargetsThreatUnit(action, threatResult) then
        priority = priority + 10000
    end
    if actionTouchesThreatBlock(action, threatResult) then
        priority = priority + 9000
    end
    if action.type == "attack" then
        priority = priority + 3000
    elseif action.type == "supply_deploy" then
        priority = priority + 2400
    elseif action.type == "repair" then
        priority = priority + 1800
    elseif action.type == "move" then
        priority = priority + 1000
    end
    return priority
end

local function normalizeLegalActionEntry(entry)
    if not entry then
        return nil
    end
    if entry.action then
        return entry
    end
    if entry.type then
        return {
            action = entry,
            type = entry.type,
            unit = entry.unit,
            target = entry.target,
            cheapScore = entry.cheapScore
        }
    end
    return nil
end

local function sortedDefenseActions(ai, state, playerId, ctx, threatResult, limit)
    local entries = ai:collectLegalActions(state, {
        aiPlayer = playerId,
        includeMove = true,
        includeAttack = true,
        includeRepair = true,
        includeDeploy = true,
        allowFullHpHealerRepairException = (((ai.AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {}).HEALER_FULL_HP_REPAIR_EXCEPTION == true
    }) or {}

    local normalized = {}
    for _, entry in ipairs(entries) do
        local item = normalizeLegalActionEntry(entry)
        if item and item.action then
            item._defensePriority = actionDefensePriority(item.action, threatResult) + num(item.cheapScore, 0) * 0.01
            normalized[#normalized + 1] = item
        end
    end

    table.sort(normalized, function(a, b)
        if a._defensePriority ~= b._defensePriority then
            return a._defensePriority > b._defensePriority
        end
        return tostring(turnEnumerator.actionSignature(a.action)) < tostring(turnEnumerator.actionSignature(b.action))
    end)

    local cap = clampLimit(limit or #normalized, 1, #normalized)
    local out = {}
    for i = 1, math.min(cap, #normalized) do
        out[#out + 1] = normalized[i]
    end
    return out
end

local function simulateTournamentActions(ai, state, actions, playerId, ctx)
    if ctx and ctx.cache and ctx.cache.simulate then
        return ctx.cache.simulate(ai, state, actions, playerId, ctx)
    end
    return ai:simulateActionSequenceForPlayer(state, actions, playerId, {})
end

local function stillHasImmediateLethal(ai, state, playerId, enemyPlayer, ctx)
    if not (state and ctx and ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal) then
        return false
    end
    return ctx.threatModel.hasImmediateCommandantLethal(ai, state, enemyPlayer, playerId, ctx) == true
end

local function makeEmergencyDefenseCandidate(actions, ctx)
    local sequence = copyArray(actions or {})
    if #sequence == 0 then
        return nil
    end

    local containsDeploy = false
    local containsAttack = false
    for _, action in ipairs(sequence) do
        if action and action.type == "supply_deploy" then
            containsDeploy = true
        elseif action and action.type == "attack" then
            containsAttack = true
        end
    end

    return {
        actions = sequence,
        signature = ctx.turnEnumerator.sequenceSignature and ctx.turnEnumerator.sequenceSignature(sequence)
            or turnEnumerator.sequenceSignature(sequence),
        source = "emergency_defense_search",
        buckets = {"anti_lethal"},
        cheapScore = 100000,
        tacticalTags = {
            preventsImmediateLoss = true,
            emergencyDefense = true
        },
        containsDeploy = containsDeploy,
        containsAttack = containsAttack,
        completeTurn = true,
        terminal = false,
        legalSkipReason = nil
    }
end

local function buildEmergencyDefenseCandidate(ai, state, ctx, threatResult)
    if not (threatResult and threatResult.immediateLethal == true and ctx and ctx.aiPlayer and ctx.enemyPlayer) then
        return nil
    end

    local playerId = ctx.aiPlayer
    local maxFirst = clampLimit(ctx.cfg.EMERGENCY_DEFENSE_MAX_FIRST_ACTIONS or 18, 6, 32)
    local maxSecond = clampLimit(ctx.cfg.EMERGENCY_DEFENSE_MAX_SECOND_ACTIONS or 18, 6, 32)
    local requiredActions = tournamentActionCount(ai)
    local firstActions = sortedDefenseActions(ai, state, playerId, ctx, threatResult, maxFirst)

    for _, firstEntry in ipairs(firstActions) do
        local first = firstEntry and firstEntry.action
        if first then
            local afterFirst = simulateTournamentActions(ai, state, {first}, playerId, ctx)
            if afterFirst then
                local firstClears = not stillHasImmediateLethal(ai, afterFirst, playerId, ctx.enemyPlayer, ctx)
                if requiredActions <= 1 and firstClears then
                    return makeEmergencyDefenseCandidate({first}, ctx)
                end

                local secondActions = sortedDefenseActions(ai, afterFirst, playerId, ctx, threatResult, maxSecond)
                if #secondActions == 0 and firstClears then
                    return makeEmergencyDefenseCandidate({first}, ctx)
                end

                for _, secondEntry in ipairs(secondActions) do
                    local second = secondEntry and secondEntry.action
                    if second and not (first.type == "supply_deploy" and second.type == "supply_deploy") then
                        local afterSecond = simulateTournamentActions(ai, state, {first, second}, playerId, ctx)
                        if afterSecond and not stillHasImmediateLethal(ai, afterSecond, playerId, ctx.enemyPlayer, ctx) then
                            return makeEmergencyDefenseCandidate({first, second}, ctx)
                        end
                    end
                end
            end
        end
    end

    return nil
end

local function prependUniqueCandidate(candidates, candidate)
    if not candidate then
        return candidates
    end
    local signature = tostring(candidate.signature or "")
    for _, existing in ipairs(candidates or {}) do
        if signature ~= "" and tostring(existing and existing.signature or "") == signature then
            return candidates
        end
    end
    local out = {candidate}
    for _, existing in ipairs(candidates or {}) do
        out[#out + 1] = existing
    end
    return out
end

local function buildDefenseLane(ai, state, ctx, baseThreat)
    local defenseThreat = threatPayload(baseThreat)
    local pressureDefense = baseThreat and baseThreat.immediateLethal ~= true and threatHasImmediateDanger(baseThreat)
    if not ((baseThreat and baseThreat.immediateLethal == true) or pressureDefense) then
        return nil
    end

    local candidates = ctx.turnEnumerator.generateFullTurnCandidates(ai, state, ctx.aiPlayer, ctx, {
        maxCandidates = clampLimit(ctx.cfg.DEFENSE_LANE_MAX_CANDIDATES or 96, 24, 160),
        maxFirstActions = clampLimit(ctx.cfg.MAX_FIRST_ACTIONS or 72, 12, 128),
        maxSecondActions = clampLimit(ctx.cfg.MAX_SECOND_ACTIONS or 36, 8, 96),
        avoidMoveAttackExposure = ctx.cfg.DEFEND_NOW_AVOID_UNSAFE_FILLER ~= false
    }) or {}

    local laneCandidates = {}
    local filterMeta = nil
    local emergencyCandidate = nil
    if baseThreat and baseThreat.immediateLethal == true then
        local safe
        safe, filterMeta = ctx.tacticalGate.filterForcedResponses(ai, state, candidates, baseThreat, ctx)
        laneCandidates = safe
        if #laneCandidates == 0 then
            laneCandidates = candidates
        end
        local emergency = buildEmergencyDefenseCandidate(ai, state, ctx, baseThreat)
        if emergency then
            emergencyCandidate = emergency
            laneCandidates = prependUniqueCandidate(laneCandidates, emergency)
            filterMeta = filterMeta or {}
            filterMeta.emergencyDefenseCandidate = true
            if ctx.stats then
                ctx.stats.emergencyDefenseCandidate = true
            end
        end
    else
        filterMeta = {forced = true, reason = "commandant_pressure"}
        for _, candidate in ipairs(candidates or {}) do
            local candidateHasSkip = candidateContainsSkip(candidate)
            local setupCandidate = (candidate and candidate.containsDeploy == true)
                or candidateTouchesThreatBlock(candidate, defenseThreat)
                or ((candidate and candidate.containsAttack ~= true) and not candidateHasSkip)
            if candidateTargetsThreatUnit(candidate, defenseThreat)
                or candidateHasDefensePressureTag(candidate)
                or setupCandidate then
                candidate.tacticalTags = candidate.tacticalTags or {}
                candidate.tacticalTags.pressureDefenseLaneCandidate = true
                if candidateTargetsThreatUnit(candidate, defenseThreat) then
                    candidate.tacticalTags.targetsCommandantThreat = true
                end
                if setupCandidate then
                    candidate.tacticalTags.pressureDefenseSetupCandidate = true
                end
                laneCandidates[#laneCandidates + 1] = candidate
            end
        end
    end

    local lane = newLane("anti_lethal", CONTRACTS.DEFEND_NOW, 1, clampLimit(ctx.cfg.CONTRACT_MIN_RANKED_PER_ACTIVE_LANE or 1, 1, 2), true)
    for _, candidate in ipairs(laneCandidates or {}) do
        addCandidateLane(candidate, "anti_lethal")
        appendUniqueBucket(candidate, "anti_lethal")
        lane.candidates[#lane.candidates + 1] = candidate
    end
    lane.emergencyCandidate = emergencyCandidate

    if ctx.stats then
        ctx.stats.forcedFiltered = true
        ctx.stats.forcedFilter = filterMeta
    end

    return lane
end

local function mergeRankedItems(target, source, ctx)
    local bySignature = {}
    for _, item in ipairs(target or {}) do
        if item and item.candidate and item.candidate.signature then
            bySignature[item.candidate.signature] = item
        end
    end

    for _, item in ipairs(source or {}) do
        if item and item.candidate and item.candidate.signature then
            local signature = item.candidate.signature
            local existing = bySignature[signature]
            if not existing or ctx.score.isBetter(item.fastScore, existing.fastScore) then
                bySignature[signature] = item
            end
        end
    end

    local merged = {}
    for _, item in pairs(bySignature) do
        merged[#merged + 1] = item
    end

    return merged
end

local function candidateSourceCounts(items)
    local counts = {}
    for _, item in ipairs(items or {}) do
        local candidate = item and item.candidate or nil
        local source = candidate and candidate.source or nil
        if not source or source == "" then
            source = item and item.lane or nil
        end
        source = tostring(source or "unknown")
        counts[source] = num(counts[source], 0) + 1
    end
    return counts
end

local rankCandidatePool

local function candidateIsFullTurnForContext(ctx, candidate)
    local actions = candidate and candidate.actions or {}
    local requiredActions = num(ctx and ctx.maxActions, 2)
    if candidate and candidate.terminal == true then
        return true
    end
    return #actions >= requiredActions
end

local function mergePipelineV2PositionHints(ai, state, ctx, ranked)
    if not (ctx
        and ctx.cfg
        and ctx.cfg.PIPELINE_V2_MERGE_POSITIONAL_CANDIDATES == true
        and ctx.pipelineV2PositionHints
        and #ctx.pipelineV2PositionHints > 0) then
        return ranked
    end

    local hints = {}
    local skippedShort = 0
    local requireFullTurn = ctx.cfg.PIPELINE_V2_MERGE_POSITIONAL_REQUIRE_FULL_TURN ~= false
    for _, candidate in ipairs(ctx.pipelineV2PositionHints or {}) do
        if requireFullTurn and not candidateIsFullTurnForContext(ctx, candidate) then
            skippedShort = skippedShort + 1
        else
            hints[#hints + 1] = candidate
        end
    end

    if ctx.stats then
        ctx.stats.pipelineV2PositionHintsEligible = #hints
        ctx.stats.pipelineV2PositionHintsSkippedShort = skippedShort
    end
    if #hints == 0 then
        return ranked
    end

    ctx.beginStage("pipeline_v2_hint_rank")
    local rankedHints = rankCandidatePool(ai, state, ctx, hints, {
        allowSoftStop = false,
        requiredLane = false,
        maxRanked = clampLimit(ctx.cfg.PIPELINE_V2_MERGE_POSITIONAL_MAX_RANKED or 8, 1, 32)
    })
    ctx.endStage("pipeline_v2_hint_rank")

    if ctx.stats then
        ctx.stats.pipelineV2PositionHintsRanked = #rankedHints
    end
    return mergeRankedItems(ranked, rankedHints, ctx)
end

function M.scoreTotalValue(scoreValue)
    if type(scoreValue) == "table" then
        return num(scoreValue.total, 0)
    end
    return num(scoreValue, 0)
end

function M.updateCoreBestSoFar(ctx, item, source, opts)
    if not (ctx and item and item.candidate and item.afterOur) then
        return
    end

    local options = opts or {}
    if options.countEvaluation ~= false then
        ctx.stats.evaluatedCandidates = num(ctx.stats.evaluatedCandidates, 0) + 1
    end

    local currentBest = ctx.bestSoFar
    local itemScore = item.finalScore or item.fastScore
    local currentScore = currentBest and (currentBest.finalScore or currentBest.fastScore) or nil
    if not currentBest or ctx.score.isBetter(itemScore, currentScore) then
        ctx.bestSoFar = item
        ctx.stats.bestSoFarAvailable = true
        ctx.stats.bestSoFarSource = source or item.source or item.candidate.source or "core"
        ctx.stats.bestSoFarSignature = item.candidate.signature
        ctx.stats.bestSoFarScore = M.scoreTotalValue(itemScore)
    end
end

function rankCandidatePool(ai, state, ctx, candidates, opts)
    local options = opts or {}
    local ranked = {}
    local bestFast = nil

    for _, candidate in ipairs(candidates or {}) do
        if not options.ignoreBudget and ctx.shouldStop and ctx.shouldStop() then
            ctx.stats.timeout = true
            break
        end
        if not options.ignoreBudget and ctx.hardStop and ctx.hardStop() then
            ctx.stats.timeout = true
            break
        end

        candidate = annotateCandidateDiagnostics(ctx.evaluator, state, candidate, ctx.aiPlayer)
        candidate = ctx.tacticalGate.annotateCandidate(ai, state, candidate, ctx)
        candidate = annotateCandidateDiagnostics(ctx.evaluator, state, candidate, ctx.aiPlayer)

        local afterOur = ctx.cache.simulate(ai, state, candidate.actions, ctx.aiPlayer, ctx)
        if not afterOur and candidate.hasFactionAttack == true and ai and ai.sanitizeActionSequenceForState then
            local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
            ctx.stats.combatExplicitSanitizeAttempts = (ctx.stats.combatExplicitSanitizeAttempts or 0) + 1
            local repaired = ai:sanitizeActionSequenceForState(state, candidate.actions, {
                aiPlayer = ctx.aiPlayer,
                maxActions = ctx.maxActions or 2,
                allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
            })
            if repaired and #repaired > 0 then
                candidate.actions = repaired
                candidate.signature = ctx.turnEnumerator.sequenceSignature(repaired)
                candidate = annotateCandidateDiagnostics(ctx.evaluator, state, candidate, ctx.aiPlayer)
                afterOur = ctx.cache.simulate(ai, state, repaired, ctx.aiPlayer, ctx)
                if afterOur then
                    candidate.sanitizerOk = true
                    ctx.stats.attackCandidateRecoveredBySanitizer = (ctx.stats.attackCandidateRecoveredBySanitizer or 0) + 1
                end
            end
            if not afterOur then
                candidate.sanitizerOk = false
                ctx.stats.combatExplicitSanitizeRejected = (ctx.stats.combatExplicitSanitizeRejected or 0) + 1
            end
        end

        if afterOur then
            if ctx.activeContracts and ctx.activeContracts.defenseKind == "pressure" then
                annotateDefenseThreatRemovalSetup(ai, state, afterOur, candidate, ctx.activeContracts, ctx)
            end
            if candidate.hasFactionAttack == true then
                classifyCombatCandidate(ai, state, candidate, afterOur, ctx, {
                    defenseActive = ctx.activeContracts and ctx.activeContracts.defenseActive == true,
                    defenseKind = ctx.activeContracts and ctx.activeContracts.defenseKind or nil,
                    defenseThreat = ctx.activeContracts and ctx.activeContracts.defenseThreat or nil,
                    drawPressureActive = ctx.stats.officialDrawUrgencyActive == true
                })
            end
            local fastScore = ctx.evaluator.scoreOwnTurnFast(ai, state, afterOur, candidate, ctx)
            if candidate.hasFactionAttack == true and candidate.combatClass then
                local classBoost = combatClassForceValue(candidate.combatClass) * num(ctx.cfg.COMBAT_CLASS_FORCE_BONUS or 220, 220)
                fastScore.force = num(fastScore.force, 0) + classBoost
                fastScore = ctx.score.finalize(fastScore)
            end
            local item = {
                candidate = candidate,
                afterOur = afterOur,
                fastScore = fastScore,
                lane = options.laneName,
                requiredLane = options.requiredLane == true
            }
            ranked[#ranked + 1] = item
            if options.trackBestSoFar == false then
                ctx.stats.evaluatedCandidates = num(ctx.stats.evaluatedCandidates, 0) + 1
            else
                M.updateCoreBestSoFar(ctx, item, options.laneName or candidate.source or "ranked")
            end
            if ctx.score.isBetter(fastScore, bestFast and bestFast.fastScore or nil) then
                bestFast = item
            end

            if options.maxRanked and #ranked >= options.maxRanked then
                break
            end
            if options.minimumRanked and #ranked >= options.minimumRanked and options.stopAfterMinimum == true then
                break
            end
        elseif candidate.hasFactionAttack == true then
            ctx.stats.attackCandidatesSimulationRejected = (ctx.stats.attackCandidatesSimulationRejected or 0) + 1
        end

        local minRankedBeforeSoftStop = num(options.minimumRanked, 0)
        if not options.ignoreBudget
            and options.allowSoftStop
            and ctx.softStop
            and ctx.softStop()
            and bestFast
            and #ranked >= minRankedBeforeSoftStop then
            break
        end
    end

    return ranked
end

local function cheapSafetyReplyCheck(ai, afterOurTurn, ctx)
    local lethal = false
    if ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal then
        lethal = ctx.threatModel.hasImmediateCommandantLethal(
            ai,
            afterOurTurn,
            ctx.enemyPlayer,
            ctx.aiPlayer,
            ctx
        ) == true
    end

    if lethal then
        return {
            total = -900000,
            riskPenalty = -900000,
            ownCommandantLethal = true,
            summary = {
                mode = "combat_safety_min_check",
                ownCommandantLethal = true,
                reason = "all_combat_candidates_allow_immediate_lethal"
            }
        }
    end

    return {
        total = 0,
        riskPenalty = 0,
        ownCommandantLethal = false,
        summary = {
            mode = "combat_safety_min_check",
            ownCommandantLethal = false,
            reason = "safe"
        }
    }
end

function M.bumpStatsCount(stats, mapName, key)
    if not stats or not mapName then
        return
    end
    local normalized = tostring(key or "unknown")
    if normalized == "" then
        normalized = "unknown"
    end
    local map = stats[mapName] or {}
    map[normalized] = num(map[normalized], 0) + 1
    stats[mapName] = map
end

function M.replyQuestionForFinalist(item, isCombatFinalist, contracts)
    local candidate = item and item.candidate or nil
    local tags = candidate and candidate.tacticalTags or {}
    if tags.winsNow == true then
        return "verify_win_now_reply"
    end
    if tags.preventsImmediateLoss == true or (contracts and contracts.defenseActive == true) then
        return "verify_defense_reply"
    end
    if tags.commandantPressure == true
        or candidateHasAnyLane(candidate, {"commandant_pressure", "direct_commandant_damage"}) then
        return "verify_commandant_pressure_reply"
    end
    if isCombatFinalist or (candidate and candidate.hasFactionAttack == true) then
        return "verify_combat_safety_reply"
    end
    if candidate and candidate.containsDeploy == true then
        return "verify_deploy_reply"
    end
    return "verify_position_reply"
end

function M.replyOutcomeKey(reply)
    local summary = reply and reply.summary
    if type(summary) == "table" then
        local mode = tostring(summary.mode or "")
        if mode == "combat_safety_min_check" then
            return summary.ownCommandantLethal == true and "cheap_reply_lethal" or "cheap_reply_safe"
        end
        local harm = num(summary.harmToUs, 0)
        if harm > 0 then
            return "scored_enemy_harm"
        end
        return "scored_enemy_zero_harm"
    end
    return tostring(summary or "unknown_reply")
end

function M.extensionQuestionForFinalist(item, isCombatFinalist, contracts)
    local candidate = item and item.candidate or nil
    local tags = candidate and candidate.tacticalTags or {}
    if tags.winsNow == true then
        return "prove_win_now"
    end
    if tags.preventsImmediateLoss == true or tags.allowsImmediateLoss == true
        or (contracts and contracts.defenseActive == true) then
        return "prove_defense_line"
    end
    if tags.commandantPressure == true
        or candidateHasAnyLane(candidate, {"commandant_pressure", "direct_commandant_damage"}) then
        return "prove_commandant_pressure"
    end
    if isCombatFinalist or (candidate and candidate.hasFactionAttack == true) then
        return "prove_combat_line"
    end
    if candidate and candidate.containsDeploy == true then
        return "prove_deploy_line"
    end
    return "prove_position_line"
end

function M.extensionOutcomeKey(extension)
    if not extension then
        return "not_run"
    end
    local result = tostring(extension.result or "unknown_extension")
    if result == "neutral" and type(extension.reasons) == "table" and extension.reasons[1] then
        return "neutral_" .. tostring(extension.reasons[1])
    end
    return result
end

local chooseBestSanitizedSelection

function M.markPreSanitizeSelectedDiagnostics(ctx, item, stage)
    if not (ctx and ctx.stats and item and item.candidate) then
        return
    end

    local candidate = item.candidate
    local tags = candidate.tacticalTags or {}
    local fastScore = item.fastScore
    local finalScore = item.finalScore or item.fastScore
    ctx.stats.preSanitizeSelectedStage = stage or "sanitize_select"
    ctx.stats.preSanitizeSelectedSignature = candidate.signature
    ctx.stats.preSanitizeCandidateSource = candidate.source
    ctx.stats.preSanitizeCandidateLane = item.lane
    ctx.stats.preSanitizeRequiredLane = item.requiredLane == true
    ctx.stats.preSanitizeEarlyPositionReason = tags.earlyPositionReason
    ctx.stats.preSanitizeEarlyPositionTarget = M.earlyPositionTargetText(tags.earlyPositionTarget)
    ctx.stats.preSanitizeContainsDeploy = candidate.containsDeploy == true
    ctx.stats.preSanitizeContainsAttack = candidate.containsAttack == true
    ctx.stats.preSanitizeFastScore = fastScore and copyScoreTuple(fastScore) or nil
    ctx.stats.preSanitizeFinalScore = finalScore and copyScoreTuple(finalScore) or nil
    ctx.stats.preSanitizeScoreDelta = num(finalScore and finalScore.total, 0)
        - num(fastScore and fastScore.total, 0)
    ctx.stats.preSanitizeReplyQuestion = item.reply and item.reply.question or nil
    ctx.stats.preSanitizeReplyOutcome = item.reply and M.replyOutcomeKey(item.reply) or nil
    ctx.stats.preSanitizeExtensionQuestion = item.extension and item.extension.question or nil
    ctx.stats.preSanitizeExtensionOutcome = item.extension and M.extensionOutcomeKey(item.extension) or nil
    ctx.stats.preSanitizeMatchesBestSoFar = candidate.signature
        and candidate.signature == ctx.stats.bestSoFarSignature
        or false
end

function M._selectedCandidateTags(selected)
    return selected and selected.candidate and selected.candidate.tacticalTags or {}
end

function M._softDefenseProofBlocked(ctx, contracts, selected)
    if ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_SOFT_DEFENSE_PROOF_GUARD_ENABLED == false then
        return false, nil
    end
    if not (contracts and contracts.defenseActive == true and contracts.defenseKind == "pressure") then
        return false, nil
    end

    local tags = M._selectedCandidateTags(selected)
    if tags.softDefensePressure ~= true then
        return false, nil
    end
    if tags.softDefensePressureReduced == true or tags.softDefensePressureCleared == true then
        return false, nil
    end

    return true, tostring(tags.softDefensePressureReason or "soft_pressure_not_reduced")
end

local function determineSelectedContract(ctx, contracts, selected)
    local candidate = selected and selected.candidate or nil
    local finalScore = selected and selected.finalScore or nil

    if finalScore and num(finalScore.tier, 0) >= ctx.score.TIER.WIN_NOW then
        return CONTRACTS.WIN_NOW
    end

    if contracts.defenseActive then
        if itemAddressesActiveDefense(ctx.selfAI, selected, contracts, ctx) then
            local blocked, reason = M._softDefenseProofBlocked(ctx, contracts, selected)
            if blocked then
                if ctx and ctx.stats then
                    ctx.stats.softDefenseProofGuardBlocked = true
                    ctx.stats.softDefenseProofGuardReason = reason
                end
            else
                return CONTRACTS.DEFEND_NOW
            end
        end
    end

    if candidate and candidate.hasFactionAttack == true then
        local combatValue = candidate.combatValue or {}
        local midTrade = candidate.midTrade or selected and selected.midTrade or {}
        local commandantDamage = math.max(
            num(combatValue.commandantDamage, 0),
            num(midTrade.commandantDamage, 0)
        )
        local kills = math.max(
            num(combatValue.kills, 0),
            num(midTrade.kills, 0)
        )
        if contracts.breakDrawClock and commandantDamage > 0 then
            return CONTRACTS.BREAK_DRAW_CLOCK
        end
        if contracts.forceCommandantPressure and commandantDamage > 0 then
            return CONTRACTS.FORCE_COMMANDANT_PRESSURE
        end
        if contracts.eliminateLowHpUnit and kills > 0 then
            return CONTRACTS.ELIMINATE_LOW_HP_UNIT
        end
        if contracts.breakDrawClock then
            return CONTRACTS.BREAK_DRAW_CLOCK
        end
        if contracts.convertWinningPosition then
            return CONTRACTS.CONVERT_WINNING_POSITION
        end
    end

    if contracts.combatActive and candidate and candidate.hasFactionAttack == true then
        return CONTRACTS.COMBAT_OR_DRAW_RESET
    end

    if candidate and candidate.hasFactionAttack == true then
        return CONTRACTS.CONVERT_ADVANTAGE
    end

    return CONTRACTS.BUILD_POSITION
end

function M._updatePipelineSelectedEvidence(ctx, contracts, item, selectedContract, defaultReason)
    if not (contracts and contracts.evidence) then
        return
    end

    local selectedSignature = item and item.candidate and item.candidate.signature or nil
    local proofReason = defaultReason
    local allowed = true

    if contracts.defenseActive == true then
        if selectedContract == CONTRACTS.DEFEND_NOW then
            proofReason = ctx.stats.passiveOverrideReason
                or (contracts.defenseKind == "pressure" and "addresses_commandant_pressure" or "defends_immediate_lethal")
            allowed = ALLOWED_PASSIVE_PROOFS[tostring(proofReason or "")] == true
            if ctx and ctx.stats then
                ctx.stats.passiveOverrideReason = proofReason
                ctx.stats.passiveOverrideForbidden = not allowed
            end
        elseif selectedContract == CONTRACTS.WIN_NOW then
            proofReason = "wins_now_without_attack"
            allowed = true
        else
            local _, softReason = M._softDefenseProofBlocked(ctx, contracts, item)
            proofReason = softReason
                or (ctx and ctx.stats and ctx.stats.defenseRaceUnresolvedReason)
                or (contracts.defenseKind == "pressure" and "defend_now_unresolved_pressure" or "defend_now_unresolved_lethal")
            allowed = false
            if ctx and ctx.stats then
                ctx.stats.passiveOverrideReason = proofReason
                ctx.stats.passiveOverrideForbidden = true
            end
        end
    end

    contracts.evidence.selectedProofReason = proofReason
    contracts.evidence.passiveOverride = contracts.evidence.passiveOverride or {}
    contracts.evidence.passiveOverride.allowed = allowed
    contracts.evidence.passiveOverride.reason = proofReason
    contracts.evidence.passiveOverride.selectedSignature = selectedSignature
end

local candidateHasEarlyResponseTrapPrefix

local function earlyBreakdownHasMoveAttackTrap(earlyBreakdown)
    return earlyBreakdownHasReason(earlyBreakdown, "early_response_move_attack_trap")
        or earlyBreakdownHasReason(earlyBreakdown, "early_move_attack_trap")
end

local function earlyBreakdownHasBadCoveredExposure(earlyBreakdown)
    return earlyBreakdownHasReason(earlyBreakdown, "early_covered_bad_trade_exposure")
        or earlyBreakdownHasReason(earlyBreakdown, "early_response_bad_covered_interdiction")
end

local PIPELINE_V2_EARLY_POSITION_SOURCES = {
    early_position_deploy_first = true,
    early_position_move = true,
    early_position_move_release = true
}

local PIPELINE_V2_EARLY_POSITION_REASON_TOKENS = {
    "occupy_free_target",
    "cover_target",
    "cover_reposition_preserves",
    "free_expand",
    "expand_next",
    "position_map_target",
    "move_cover_owned_uncovered",
    "move_uncovered_occupy_better",
    "release_cover_then",
    "release_occupant_then",
    "then_position"
}

function M.pipelineV2EarlyPositionRetreatAllowedForGate(ctx, itemOrCandidate)
    if not (ctx
        and ctx.cfg
        and ctx.cfg.EARLY_GATE_ALLOW_PIPELINE_V2_POSITIONAL_RETREAT == true) then
        return false
    end

    local candidate = itemOrCandidate and itemOrCandidate.candidate or itemOrCandidate
    if not candidate then
        return false
    end
    if candidate.hasFactionAttack == true or candidate.containsAttack == true then
        return false
    end
    if not candidateIsFullTurnForContext(ctx, candidate) then
        return false
    end

    local source = tostring(candidate.source or "")
    if PIPELINE_V2_EARLY_POSITION_SOURCES[source] ~= true then
        return false
    end

    local tags = candidate.tacticalTags or {}
    local reason = tostring(tags.earlyPositionReason or "")
    if reason == "" then
        return false
    end

    for _, token in ipairs(PIPELINE_V2_EARLY_POSITION_REASON_TOKENS) do
        if reason:find(token, 1, true) then
            return true
        end
    end

    return false
end

local budgetStop

local function distanceBetweenCells(a, b)
    if not (a and b and a.row and a.col and b.row and b.col) then
        return 99
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function findEarlyCommittedAttackers(ai, state, ctx, item)
    local candidate = item and item.candidate or nil
    local enemyHub = state and state.commandHubs and state.commandHubs[ctx.enemyPlayer]
    if not (candidate and enemyHub) then
        return {}
    end

    local committed = {}
    local currentState = state
    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "attack" and currentState and isFactionAttack(ctx, currentState, action, ctx.aiPlayer) then
            local attacker = getUnitAt(ai, currentState, action.unit and action.unit.row, action.unit and action.unit.col)
            local target = getActionTargetUnit(ai, currentState, action)
            if attacker and target and tostring(target.name or "") ~= "Commandant" then
                local damage = 0
                if ai and ai.calculateDamage then
                    damage = num(ai:calculateDamage(attacker, target), 0)
                end
                local targetHp = num(target.currentHp or target.startingHp, 0)
                local targetValue = 0
	                if ai and ai.getUnitBaseValue then
	                    targetValue = num(ai:getUnitBaseValue(target, currentState), 0)
	                end
	                local attackerHp = num(attacker.currentHp or attacker.startingHp, 0)
	                local attackerStartingHp = num(attacker.startingHp, attackerHp)
	                committed[#committed + 1] = {
	                    name = attacker.name,
	                    row = attacker.row,
	                    col = attacker.col,
	                    hp = attackerHp,
	                    startingHp = attackerStartingHp,
	                    targetName = target.name,
	                    damage = damage,
	                    killed = targetHp > 0 and damage >= targetHp,
                    targetValue = targetValue,
                    hubDistance = distanceBetweenCells(attacker, enemyHub)
                }
            end
        end

        if currentState then
            currentState = (ctx and ctx.cache and ctx.cache.simulate)
                and ctx.cache.simulate(ai, currentState, {action}, ctx.aiPlayer, ctx)
                or (ai and ai.simulateActionSequenceForPlayer and ai:simulateActionSequenceForPlayer(currentState, {action}, ctx.aiPlayer, {}))
        end
    end

    return committed
end

function earlyAttackCommitmentRejects(ai, state, ctx, contracts, item)
    if not (ctx
        and ctx.cfg
        and ctx.cfg.EARLY_ATTACK_COMMITMENT_GATE_ENABLED == true
        and ctx.phase
        and ctx.phase.early == true
        and item
        and item.candidate
        and item.candidate.hasFactionAttack == true) then
        return false, nil
    end

    if contracts and contracts.defenseActive == true then
        return false, "defend_now"
    end

    local proof = tacticalOverrideReasonForItem(ai, ctx, state, item, contracts)
    if proof == "win_now"
        or proof == "defend_now"
        or proof == "commandant_pressure"
        or proof == "commandant_pressure_setup"
        or proof == "winning_race"
        or proof == "draw_pressure" then
        return false, proof
    end

	local candidate = item.candidate
	local combatValue = candidate.combatValue or {}
	if num(combatValue.commandantDamage, 0) > 0 then
	    return false, "commandant_pressure"
	end

	local committed = findEarlyCommittedAttackers(ai, state, ctx, item)
	if #committed == 0 then
	    return false, proof
	end

	local replyState = item.reply and item.reply.afterEnemy or nil
	local beforeFeatures = nil
	local afterReplyFeatures = nil
	local materialGain = nil
	local boardDelta = nil
	local function computeReplyDeltas()
	    if materialGain ~= nil and boardDelta ~= nil then
	        return materialGain, boardDelta
	    end
	    beforeFeatures = beforeFeatures or (ctx.cache and ctx.cache.features and ctx.cache.features(ai, state, ctx.aiPlayer, ctx)) or {}
	    afterReplyFeatures = replyState
	        and ((ctx.cache and ctx.cache.features and ctx.cache.features(ai, replyState, ctx.aiPlayer, ctx)) or {})
	        or {}
	    materialGain = num(afterReplyFeatures.materialDiff, 0) - num(beforeFeatures.materialDiff, 0)
	    local beforeBoard = num(beforeFeatures.ownUnitCount, 0) - num(beforeFeatures.enemyUnitCount, 0)
	    local afterBoard = num(afterReplyFeatures.ownUnitCount, 0) - num(afterReplyFeatures.enemyUnitCount, 0)
	    boardDelta = afterBoard - beforeBoard
	    return materialGain, boardDelta
	end

	local woundedRatioMax = num(ctx.cfg.EARLY_WOUNDED_RETALIATION_HP_RATIO_MAX, 0.5)
	for _, entry in ipairs(committed) do
	    local hp = num(entry.hp, 0)
	    local startingHp = math.max(1, num(entry.startingHp, hp))
	    local wounded = hp > 0 and (hp / startingHp) <= woundedRatioMax
	    if wounded and entry.killed ~= true and num(entry.damage, 0) > 0 then
	        if not replyState then
	            return true, "early_wounded_retaliation_requires_reply"
	        end
	        local afterReplyUnit = getUnitAt(ai, replyState, entry.row, entry.col)
	        local diesToReply = not (
	            afterReplyUnit
	            and afterReplyUnit.player == ctx.aiPlayer
	            and afterReplyUnit.name == entry.name
	        )
	        if diesToReply then
	            local replyMaterialGain, replyBoardDelta = computeReplyDeltas()
	            local materialMin = num(ctx.cfg.EARLY_ATTACK_COMMITMENT_MATERIAL_GAIN_MIN, 45)
	            local boardMin = num(ctx.cfg.EARLY_ATTACK_COMMITMENT_BOARD_DELTA_MIN, 0)
	            if not (replyMaterialGain >= materialMin and replyBoardDelta >= boardMin) then
	                if ctx.stats then
	                    ctx.stats.earlyAttackCommitmentMaterialGain = replyMaterialGain
	                    ctx.stats.earlyAttackCommitmentBoardDelta = replyBoardDelta
	                end
	                return true, "early_wounded_retaliation_bad_trade"
	            end
	        end
	    end
	end

	local radius = num(ctx.cfg.EARLY_ATTACK_COMMITMENT_HUB_RADIUS, 2)
	local nearHubCommit = false
	local committedDies = false
	local committedKill = false
	for _, entry in ipairs(committed) do
        if entry.hubDistance <= radius then
            nearHubCommit = true
            committedKill = committedKill or entry.killed == true
            if replyState then
                local afterReplyUnit = getUnitAt(ai, replyState, entry.row, entry.col)
                if not (afterReplyUnit and afterReplyUnit.player == ctx.aiPlayer and afterReplyUnit.name == entry.name) then
                    committedDies = true
                end
            end
        end
    end

    if not nearHubCommit then
        return false, proof
    end
    if not replyState then
        return true, "early_commitment_requires_reply"
    end
    if committedDies ~= true then
        return false, proof or "attacker_survives"
    end

	materialGain, boardDelta = computeReplyDeltas()
	local materialMin = num(ctx.cfg.EARLY_ATTACK_COMMITMENT_MATERIAL_GAIN_MIN, 45)
	local boardMin = num(ctx.cfg.EARLY_ATTACK_COMMITMENT_BOARD_DELTA_MIN, 0)

    if ctx.stats then
        ctx.stats.earlyAttackCommitmentMaterialGain = materialGain
        ctx.stats.earlyAttackCommitmentBoardDelta = boardDelta
    end

    if materialGain >= materialMin and boardDelta >= boardMin then
        return false, "material_gain"
    end

    if committedKill then
        return true, "early_overcommitted_vanguard_trade"
    end

    return true, "early_overcommitted_vanguard_attack"
end

local function chooseEarlyAttackCommitmentAlternative(ai, state, ctx, contracts, alternatives)
    if budgetStop(ctx) then
        return nil, nil
    end
    local viable = {}
    local seen = {}
    for _, item in ipairs(alternatives or {}) do
        if budgetStop(ctx) then
            break
        end
        local candidate = item and item.candidate or nil
        local signature = tostring(candidate and candidate.signature or "")
        if candidate and signature ~= "" and not seen[signature] then
            seen[signature] = true
            local rejected = earlyAttackCommitmentRejects(ai, state, ctx, contracts, item)
            if not rejected then
                viable[#viable + 1] = item
            end
        end
    end

    if #viable == 0 then
        return nil, nil
    end

    table.sort(viable, function(a, b)
        return ctx.score.isBetter(a and (a.finalScore or a.fastScore) or nil, b and (b.finalScore or b.fastScore) or nil)
    end)

    return chooseBestSanitizedSelection(ai, state, ctx, viable[1], viable)
end

local function sanitizeTournamentSequenceForContext(ai, state, sequence, ctx, options)
    if not ai or not state or type(sequence) ~= "table" or #sequence == 0 then
        return nil, nil
    end

    options = options or {}
    local tournamentConfig = ai.getTournamentConfig and ai:getTournamentConfig() or {}
    local requireSanitized = tournamentConfig.REQUIRE_SANITIZED_SEQUENCE == true
        or options.requireExact == true
    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local sanitized = sequence
    local sanitizeSummary = {
        replacements = 0,
        reasonCounts = {}
    }

    if ai.sanitizeActionSequenceForState then
        sanitized, sanitizeSummary = ai:sanitizeActionSequenceForState(state, sequence, {
            aiPlayer = ctx.aiPlayer,
            maxActions = ctx.maxActions or 2,
            allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true,
            rejectZeroDamageFactionAttacks = true,
            allowVoluntarySkip = options.allowVoluntarySkip == true
        })
    end

    local replacements = num(sanitizeSummary and sanitizeSummary.replacements, 0)
    local accepted = sanitized and #sanitized > 0 and (not requireSanitized or replacements == 0)
    if not accepted then
        return nil, sanitizeSummary
    end

    local simulated = ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, sanitized, ctx.aiPlayer, ctx)
        or ai:simulateActionSequenceForPlayer(state, sanitized, ctx.aiPlayer, {})
    if not simulated then
        return nil, sanitizeSummary
    end

    return sanitized, sanitizeSummary
end

function M._materializeHardPunishSelection(ai, state, ctx, contracts, punish)
    if not (punish and punish.actions and #punish.actions > 0) then
        return nil, nil, "missing_hard_punish_actions"
    end

    local source = "hard_punish"
    local buckets = {"hard_punish", "direct_kill"}
    if punish.kind == "move_attack_safe_kill" then
        buckets[#buckets + 1] = "move_attack"
    elseif punish.kind == "two_unit_safe_kill" then
        buckets[#buckets + 1] = "two_unit_kill"
    elseif punish.kind == "cloudstriker_los_safe_kill" then
        buckets[#buckets + 1] = "cloudstriker_los"
        buckets[#buckets + 1] = "move_attack"
    elseif punish.kind == "ranged_commandant_pressure" then
        buckets[2] = "direct_commandant_damage"
        buckets[#buckets + 1] = "ranged_commandant_pressure"
    elseif punish.kind == "move_ranged_commandant_pressure" then
        buckets[2] = "direct_commandant_damage"
        buckets[#buckets + 1] = "ranged_commandant_pressure"
        buckets[#buckets + 1] = "move_attack"
    else
        buckets[#buckets + 1] = "direct_attack"
    end

    local isSafePressure = punish.kind == "ranged_commandant_pressure"
        or punish.kind == "move_ranged_commandant_pressure"
    local hardPunishContract = punish.defensePressureResolved == true
        and CONTRACTS.DEFEND_NOW
        or CONTRACTS.COMBAT_OR_DRAW_RESET

    local tacticalTags = {
        hardPunish = true,
        hardPunishKind = punish.kind,
        hardPunishProof = punish.proof,
        hardPunishTargetName = punish.targetName,
        safeKill = not isSafePressure,
        safeCommandantPressure = isSafePressure,
        defendNowSafeKill = punish.defensePressureResolved == true,
        targetsCommandantThreat = punish.defensePressureResolved == true
    }

    local candidate = nil
    local afterOur = nil
    if #punish.actions == 1 then
        candidate, afterOur = buildCandidateFromFirstAction(ai, state, ctx.aiPlayer, ctx, punish.actions[1], {
            source = source,
            buckets = buckets,
            tacticalTags = tacticalTags,
            contract = hardPunishContract,
            avoidUnsafeFiller = ctx and ctx.cfg and ctx.cfg.HARD_PREFIX_AVOID_UNSAFE_FILLER ~= false
        })
    else
        afterOur = ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, punish.actions, ctx.aiPlayer, ctx)
            or ai:simulateActionSequenceForPlayer(state, punish.actions, ctx.aiPlayer, {})
        if afterOur then
            candidate = buildCandidate(ctx, punish.actions, {
                source = source,
                buckets = buckets,
                tacticalTags = tacticalTags,
                contract = hardPunishContract
            })
        end
    end

    if not (candidate and afterOur and candidate.actions and #candidate.actions > 0) then
        return nil, nil, "hard_punish_materialize_failed"
    end

    local sanitized, sanitizeSummary = sanitizeTournamentSequenceForContext(ai, state, candidate.actions, ctx, {
        requireExact = true
    })
    if not sanitized then
        return nil, sanitizeSummary, "hard_punish_sanitize_rejected"
    end

    afterOur = ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, sanitized, ctx.aiPlayer, ctx)
        or ai:simulateActionSequenceForPlayer(state, sanitized, ctx.aiPlayer, {})
    if not afterOur then
        return nil, sanitizeSummary, "hard_punish_simulation_failed"
    end

    candidate = buildCandidate(ctx, sanitized, {
        source = source,
        buckets = buckets,
        tacticalTags = tacticalTags,
        contract = hardPunishContract
    })
    candidate.sanitizerOk = true
    candidate = annotateCandidateDiagnostics(ctx.evaluator, state, candidate, ctx.aiPlayer)
    candidate = ctx.tacticalGate.annotateCandidate(ai, state, candidate, ctx)
    candidate = annotateCandidateDiagnostics(ctx.evaluator, state, candidate, ctx.aiPlayer)
    classifyCombatCandidate(ai, state, candidate, afterOur, ctx, contracts)

    local attackSummary = analyzeFactionAttackSequence(ai, state, candidate, ctx.aiPlayer, ctx)
    local isSafePressure = punish.kind == "ranged_commandant_pressure"
        or punish.kind == "move_ranged_commandant_pressure"
    local verified = candidate.hasFactionAttack == true
        and (
            num(attackSummary and attackSummary.kills, 0) > 0
            or (isSafePressure and num(attackSummary and attackSummary.commandantDamage, 0) > 0)
        )
    if not verified then
        return nil,
            sanitizeSummary,
            isSafePressure and "hard_punish_no_verified_commandant_pressure" or "hard_punish_no_verified_kill"
    end

    local fastScore = ctx.evaluator.scoreOwnTurnFast(ai, state, afterOur, candidate, ctx)
    local item = {
        candidate = candidate,
        afterOur = afterOur,
        fastScore = fastScore,
        finalScore = fastScore,
        reply = {
            total = 0,
            summary = "hard_punish_pre_v2",
            question = punish.kind or "hard_punish"
        },
        extension = nil,
        lane = "hard_punish",
        requiredLane = true,
        leavesImmediateLethal = false
    }

    return item, sanitizeSummary, nil
end

function M._enemyEliminatedAfterState(state, enemyPlayer)
    if not (state and enemyPlayer) then
        return false
    end

    for _, unit in ipairs(state.units or {}) do
        if unit
            and unit.player == enemyPlayer
            and unit.name ~= "Commandant"
            and unit.name ~= "Rock" then
            return false
        end
    end

    return #((state.supply and state.supply[enemyPlayer]) or {}) <= 0
end

function M._materializeHardWinSelection(ai, state, ctx, win)
    if not (win and win.actions and #win.actions > 0) then
        return nil, nil, "missing_hard_win_actions"
    end

    local tacticalTags = {
        hardWin = true,
        hardWinKind = win.kind,
        hardWinProof = win.proof,
        hardWinSourceReason = win.sourceReason,
        winsNow = true
    }
    local candidate = buildCandidate(ctx, win.actions, {
        source = "hard_win",
        buckets = {"hard_win", "lethal"},
        tacticalTags = tacticalTags,
        terminal = true,
        legalSkipReason = "terminal_win",
        contract = CONTRACTS.WIN_NOW
    })

    local sanitized, sanitizeSummary = sanitizeTournamentSequenceForContext(ai, state, candidate.actions, ctx, {
        requireExact = true
    })
    if not sanitized then
        return nil, sanitizeSummary, "hard_win_sanitize_rejected"
    end

    local afterOur = ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, sanitized, ctx.aiPlayer, ctx)
        or ai:simulateActionSequenceForPlayer(state, sanitized, ctx.aiPlayer, {})
    if not afterOur then
        return nil, sanitizeSummary, "hard_win_simulation_failed"
    end

    local commandantWin = ctx.evaluator.isCommandantDead(afterOur, ctx.enemyPlayer) == true
    local eliminationWin = win.kind == "last_enemy_unit"
        and M._enemyEliminatedAfterState(afterOur, ctx.enemyPlayer) == true
    if not (commandantWin or eliminationWin) then
        return nil, sanitizeSummary, "hard_win_not_verified"
    end

    candidate = buildCandidate(ctx, sanitized, {
        source = "hard_win",
        buckets = {"hard_win", "lethal"},
        tacticalTags = tacticalTags,
        terminal = true,
        legalSkipReason = "terminal_win",
        contract = CONTRACTS.WIN_NOW
    })
    candidate.sanitizerOk = true
    candidate = annotateCandidateDiagnostics(ctx.evaluator, state, candidate, ctx.aiPlayer)
    candidate = ctx.tacticalGate.annotateCandidate(ai, state, candidate, ctx)
    candidate = annotateCandidateDiagnostics(ctx.evaluator, state, candidate, ctx.aiPlayer)

    local fastScore = ctx.evaluator.scoreOwnTurnFast(ai, state, afterOur, candidate, ctx)
    fastScore.tier = ctx.score.TIER.WIN_NOW
    fastScore.terminal = 1000000
    fastScore.signature = candidate.signature
    fastScore = ctx.score.finalize(fastScore)

    local item = {
        candidate = candidate,
        afterOur = afterOur,
        fastScore = fastScore,
        finalScore = fastScore,
        reply = {
            total = 0,
            summary = "hard_win_priority00",
            question = win.kind or "win_now"
        },
        extension = nil,
        lane = "hard_win",
        requiredLane = true,
        leavesImmediateLethal = false
    }

    return item, sanitizeSummary, nil
end

local function applySanitizedSequenceToItem(ai, state, ctx, item, options)
    if not (item and item.candidate and type(item.candidate.actions) == "table") then
        return nil, nil
    end
    local sanitized, sanitizeSummary = sanitizeTournamentSequenceForContext(
        ai,
        state,
        item.candidate.actions,
        ctx,
        options
    )
    if not sanitized then
        return nil, sanitizeSummary
    end
    M.markPreSanitizeSelectedDiagnostics(
        ctx,
        item,
        options and options.diagnosticStage
            or (options and options.requireExact and "hard_sanitize" or "sanitize_select")
    )
    item.candidate.actions = sanitized
    item.candidate.signature = ctx.turnEnumerator.sequenceSignature(sanitized)
    item.candidate.sanitizerOk = true
    local simulated = ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, sanitized, ctx.aiPlayer, ctx)
        or ai:simulateActionSequenceForPlayer(state, sanitized, ctx.aiPlayer, {})
    if not simulated then
        return nil, sanitizeSummary
    end
    item.afterOur = simulated
    item.candidate = annotateCandidateDiagnostics(ctx.evaluator, state, item.candidate, ctx.aiPlayer)
    item.candidate = ctx.tacticalGate.annotateCandidate(ai, state, item.candidate, ctx)
    item.candidate = annotateCandidateDiagnostics(ctx.evaluator, state, item.candidate, ctx.aiPlayer)
    classifyCombatCandidate(ai, state, item.candidate, simulated, ctx, ctx.activeContracts)
    local fastScore = ctx.evaluator.scoreOwnTurnFast(ai, state, simulated, item.candidate, ctx)
    item.fastScore = fastScore
    item.finalScore = fastScore
    local previousReplyQuestion = item.reply and item.reply.question or nil
    item.reply = {
        total = 0,
        summary = "sanitized_rescore",
        question = previousReplyQuestion or "sanitize_select"
    }
    item.extension = nil
    item.leavesImmediateLethal = item.candidate
        and item.candidate.combatSafety
        and item.candidate.combatSafety.allowsImmediateOwnLethal == true
    return item, sanitizeSummary
end

chooseBestSanitizedSelection = function(ai, state, ctx, primary, alternatives)
    local seen = {}
    local lastSummary = nil
    local attempts = 0

    local function keyFor(item)
        if not item or not item.candidate then
            return nil
	end
        return tostring(item.candidate.signature or "")
    end

    local function tryItem(item)
        local key = keyFor(item)
        if key == nil then
            return nil
        end
        if key ~= "" and seen[key] then
            return nil
        end
        if key ~= "" then
            seen[key] = true
        end
        attempts = attempts + 1
        if ctx and ctx.stats then
            ctx.stats.sanitizerCandidateAttempts = num(ctx.stats.sanitizerCandidateAttempts, 0) + 1
        end
        if itemHasDisallowedNeutralAttack(ai, state, ctx, item) then
            if ctx and ctx.stats then
                ctx.stats.nonStrategicNeutralAttackRejected =
                    num(ctx.stats.nonStrategicNeutralAttackRejected, 0) + 1
                ctx.stats.neutralAttackRejectReason = "non_strategic_neutral_attack"
            end
            return nil
        end
        local accepted, summary = applySanitizedSequenceToItem(ai, state, ctx, item)
        if summary then
            lastSummary = summary
        end
        if not accepted and ctx and ctx.stats then
            ctx.stats.sanitizerCandidateRejected = num(ctx.stats.sanitizerCandidateRejected, 0) + 1
        end
        return accepted
    end

    local acceptedPrimary = tryItem(primary)
    if acceptedPrimary then
        return acceptedPrimary, lastSummary
    end

    for _, item in ipairs(alternatives or {}) do
        local accepted = tryItem(item)
        if accepted then
            if ctx and ctx.stats then
                ctx.stats.sanitizerAlternativeAccepted =
                    item and item.candidate and item.candidate.signature or "selected"
                ctx.stats.sanitizerAlternativeAcceptedAfterAttempts = attempts
            end
            return accepted, lastSummary
        end
    end

	return nil, lastSummary
end

local function selectEmergencyDefenseFallback(ai, state, ctx, contracts, baseThreat, candidate)
    if not (contracts and contracts.defenseActive == true and contracts.defenseKind ~= "pressure") then
        return nil, nil, "not_hard_defense"
    end
    if not (baseThreat and baseThreat.immediateLethal == true) then
        return nil, nil, "not_immediate_lethal"
    end

    local emergency = candidate or buildEmergencyDefenseCandidate(ai, state, ctx, baseThreat)
    if not emergency then
        return nil, nil, "no_emergency_defense_candidate"
    end

    if ctx and ctx.stats then
        ctx.stats.emergencyDefenseFallbackAttempted = true
        ctx.stats.emergencyDefenseFallbackSignature = emergency.signature
    end

    local ranked = rankCandidatePool(ai, state, ctx, {emergency}, {
        laneName = "emergency_defense_fallback",
        requiredLane = true,
        minimumRanked = 1,
        maxRanked = 1,
        ignoreBudget = true,
        trackBestSoFar = false
    })
    if ctx and ctx.stats then
        ctx.stats.emergencyDefenseFallbackRanked = #(ranked or {})
    end

    local lastSummary = nil
    for _, item in ipairs(ranked or {}) do
        local sanitized, summary = chooseBestSanitizedSelection(ai, state, ctx, item, {item})
        lastSummary = summary or lastSummary
        if sanitized and M.hardLockReasonForSelection(ai, state, ctx, contracts, sanitized) == "defend_now" then
            if ctx and ctx.stats then
                ctx.stats.emergencyDefenseFallbackSelected = true
                ctx.stats.emergencyDefenseFallbackSelectedSignature =
                    sanitized.candidate and sanitized.candidate.signature or nil
            end
            return sanitized, lastSummary, nil
        end
    end

    return nil, lastSummary, "emergency_defense_fallback_rejected"
end

local function enforcePassiveOverrideProof(
    state,
    ctx,
    contracts,
    selected,
    bestSafeCombat,
    bestCombatAny,
    bestDefense,
    bestNonCombat,
    bestNonDeployNonCombat
)
    if not contracts.combatActive and not contracts.defenseActive then
        return selected
    end

    local function winsNow(item)
        local scoreValue = item and item.finalScore or nil
        return scoreValue and num(scoreValue.tier, 0) >= ctx.score.TIER.WIN_NOW
    end

    local function resolvesImmediateDefense(item)
        if not contracts.defenseActive then
            return true, nil
        end
        local resolves = itemAddressesActiveDefense(ctx.selfAI, item, contracts, ctx)
        local stillLethal = nil
        if item and item.afterOur and ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal then
            stillLethal = ctx.threatModel.hasImmediateCommandantLethal(
                ctx.selfAI,
                item.afterOur,
                ctx.enemyPlayer,
                ctx.aiPlayer,
                ctx
            ) == true
        end
        return resolves == true, stillLethal
    end

    local selectedCandidate = selected and selected.candidate or nil
    local selectedTags = selectedCandidate and selectedCandidate.tacticalTags or {}
    local selectedScore = selected and selected.finalScore or nil
    local selectedWinsNow = winsNow(selected)
    local selectedDefendsImmediate, selectedStillLethal = resolvesImmediateDefense(selected)
    if selectedCandidate and selectedCandidate.tacticalTags then
        selectedTags = selectedCandidate.tacticalTags
    end

    local function bestHardCombatItem()
        local bestItem = nil
        for _, item in ipairs({bestSafeCombat, bestCombatAny}) do
            if item
                and itemHasHardCombatOverride(ctx.selfAI, ctx, state, item, contracts)
                and ctx.score.isBetter(item.finalScore or item.fastScore, bestItem and (bestItem.finalScore or bestItem.fastScore) or nil) then
                bestItem = item
            end
        end
        return bestItem
    end

    local bestHardCombat = bestHardCombatItem()

    local function bestDefenseRaceWinItem()
        if not (contracts and contracts.defenseActive == true and contracts.defenseKind == "pressure") then
            return nil, nil
        end
        local defenseTTD = finiteNumberOrNil(contracts.defenseRaceTTD)
        if not defenseTTD then
            return nil, nil
        end

        local seen = {}
        local pool = {selected, bestSafeCombat, bestCombatAny}
        local bestItem = nil
        local bestTTW = nil
        for _, item in ipairs(pool) do
            local signature = tostring(item and item.candidate and item.candidate.signature or "")
            if signature ~= "" and not seen[signature] then
                seen[signature] = true
                local candidate = item and item.candidate or nil
                local safeAttack = candidate
                    and candidate.hasFactionAttack == true
                    and candidate.sanitizerOk ~= false
                    and candidate.combatSafety
                    and candidate.combatSafety.safe == true
                if safeAttack then
                    local ttw = estimateCandidateWinRaceTTW(ctx.selfAI, state, item, ctx)
                    if ttw and ttw <= defenseTTD then
                        if (not bestItem) or ctx.score.isBetter(item.finalScore or item.fastScore, bestItem.finalScore or bestItem.fastScore) then
                            bestItem = item
                            bestTTW = ttw
                        end
                    end
                end
            end
        end
        return bestItem, bestTTW
    end

    local winRaceItem, winRaceTTW = bestDefenseRaceWinItem()
    if winRaceItem and not selectedWinsNow then
        contracts.defenseRaceWinRaceConfirmed = true
        ctx.stats.defenseRaceRejectedByWinRace = true
        ctx.stats.defenseRaceProof = "win_race"
        ctx.stats.defenseRaceTTW = num(winRaceTTW, ctx.stats.defenseRaceTTW)
        ctx.stats.passiveOverrideReason = "defense_race_win"
        ctx.stats.passiveOverrideForbidden = false
        if winRaceItem.candidate then
            winRaceItem.candidate.tacticalTags = winRaceItem.candidate.tacticalTags or {}
            winRaceItem.candidate.tacticalTags.defenseRaceProof = "win_race"
            winRaceItem.candidate.tacticalTags.defenseRaceBestETA = num(winRaceTTW, 0)
            winRaceItem.candidate.tacticalTags.preventsImmediateLoss = true
            winRaceItem.candidate.tacticalTags.addressesCommandantPressure = true
        end
        ctx.stats.combatSelected = (ctx.stats.combatSelected or 0) + 1
        return winRaceItem
    end

    if selectedCandidate and selectedCandidate.hasFactionAttack == true then
        local selectedUnsafe = not (selectedCandidate.combatSafety and selectedCandidate.combatSafety.safe == true)
        local selectedSafetyReason = tostring(selectedCandidate.combatSafety and selectedCandidate.combatSafety.reason or "none")
        local selectedUnsafeForOwnLethal = selectedUnsafe and selectedSafetyReason == "allows_immediate_own_commandant_lethal"
        local canOverrideUnsafeCombat = selectedUnsafeForOwnLethal
            and (not contracts.defenseActive)
            and num(ctx.stats.combatRanked, 0) == 0
        if canOverrideUnsafeCombat and not selectedWinsNow and bestNonCombat and bestNonCombat ~= selected then
            ctx.stats.combatSkippedWithProof = (ctx.stats.combatSkippedWithProof or 0) + 1
            ctx.stats.passiveOverrideReason = "unsafe_combat_rejected_for_commandant_safety"
            ctx.stats.passiveOverrideForbidden = false
            return bestNonCombat
        end

        if contracts.defenseActive and selectedDefendsImmediate ~= true and not selectedWinsNow then
            local forcedDefense = nil
            local forcedReason = nil
            if bestDefense and bestDefense ~= selected and resolvesImmediateDefense(bestDefense) then
                forcedDefense = bestDefense
                forcedReason = "forced_defense_over_combat"
            end
            if (not forcedDefense) and bestSafeCombat and resolvesImmediateDefense(bestSafeCombat) then
                forcedDefense = bestSafeCombat
                forcedReason = "forced_defense_safe_combat"
            end
            if (not forcedDefense) and bestCombatAny and bestCombatAny ~= selected and resolvesImmediateDefense(bestCombatAny) then
                forcedDefense = bestCombatAny
                forcedReason = "forced_defense_safe_combat"
            end
            if forcedDefense then
                ctx.stats.passiveOverrideReason = forcedReason
                ctx.stats.passiveOverrideForbidden = false
                ctx.stats.combatSelected = (ctx.stats.combatSelected or 0) + 1
                return forcedDefense
            end
            ctx.stats.combatSkippedWithoutProof = (ctx.stats.combatSkippedWithoutProof or 0) + 1
            ctx.stats.passiveOverrideReason = contracts.defenseKind == "pressure"
                and "defend_now_unresolved_pressure"
                or "defend_now_unresolved_lethal"
            ctx.stats.passiveOverrideForbidden = true
            return selected
        end
        ctx.stats.combatSelected = (ctx.stats.combatSelected or 0) + 1
        return selected
    end

    local proofReason = nil
    local forbiddenReason = nil
    local bestSafeScore = bestSafeCombat and bestSafeCombat.finalScore or nil
    local drawPressure = contracts.drawPressureActive == true
    local drawNearLimit = drawPressure
        and num(ctx.stats and ctx.stats.drawStreak, 0)
            >= math.max(0, num(ctx.stats and ctx.stats.officialDrawNoInteractionLimit, 5) - 2)
    local drawHasCombatAlternative = bestSafeCombat ~= nil or bestCombatAny ~= nil

    if selectedWinsNow then
        proofReason = "wins_now_without_attack"
    elseif contracts.defenseActive then
        local defendsImmediate = selectedTags.preventsImmediateLoss == true or selectedDefendsImmediate == true
        if defendsImmediate and selectedStillLethal ~= true then
            proofReason = contracts.defenseKind == "pressure"
                and "addresses_commandant_pressure"
                or "defends_immediate_lethal"
        else
            forbiddenReason = contracts.defenseKind == "pressure"
                and "defend_now_unresolved_pressure"
                or "defend_now_unresolved_lethal"
        end
    elseif selected and selected.extension and selected.extension.result == "proved_force" then
        proofReason = "verified_noncombat_forced_win"
    elseif progressiveNonCombatBeatsLowValueCombat(
        ctx.selfAI,
        state,
        selected,
        bestSafeCombat or bestCombatAny,
        ctx,
        contracts
    ) then
        proofReason = "progressive_setup_beats_low_value_combat"
    elseif drawNearLimit and drawHasCombatAlternative then
        forbiddenReason = "draw_clock_requires_interaction"
    elseif (bestSafeCombat or bestCombatAny) and not bestHardCombat then
        proofReason = "soft_combat_deferred_to_turn_score"
    elseif num(ctx.stats.legalAttackActions, 0) <= 0 and num(ctx.stats.legalMoveAttackActions, 0) <= 0 then
        proofReason = "no_legal_faction_attack_available"
    elseif num(ctx.stats.legalAttackActions, 0) > 0 and num(ctx.stats.combatDirectGenerated, 0) <= 0 then
        forbiddenReason = "combat_lane_generation_failed"
    elseif num(ctx.stats.legalAttackActions, 0) <= 0
        and num(ctx.stats.legalMoveAttackActions, 0) > 0
        and num(ctx.stats.combatMoveAttackGenerated, 0) <= 0
        and num(ctx.stats.combatGeneratedTotal, 0) <= 0 then
        proofReason = "no_safe_move_attack_available"
    elseif num(ctx.stats.combatGeneratedTotal, 0) > 0
        and num(ctx.stats.combatRanked, 0) == 0
        and num(ctx.stats.combatDirectGenerated, 0) > 0
        and num(ctx.stats.combatExplicitSanitizeRejected, 0) >= num(ctx.stats.combatGeneratedTotal, 0)
        and num(ctx.stats.combatExplicitSanitizeAttempts, 0) >= num(ctx.stats.combatGeneratedTotal, 0)
        and ctx.stats.timeout ~= true then
        proofReason = "all_combat_candidates_illegal_after_explicit_sanitize"
    elseif num(ctx.stats.combatGeneratedTotal, 0) > 0
        and num(ctx.stats.combatRanked, 0) == 0
        and ctx.stats.timeout ~= true then
        proofReason = "all_combat_candidates_unviable_after_generation"
    elseif num(ctx.stats.combatRanked, 0) > 0 and num(ctx.stats.combatSafeRanked, 0) == 0 then
        proofReason = "all_combat_candidates_allow_immediate_lethal"
    elseif num(ctx.stats.combatGeneratedTotal, 0) > 0 and num(ctx.stats.combatRanked, 0) == 0 and ctx.stats.timeout == true then
        forbiddenReason = "combat_skipped_by_budget"
    elseif not drawPressure
        and not contracts.convertWinningPosition
        and not contracts.forceCommandantPressure
        and not contracts.eliminateLowHpUnit
        and selectedScore
        and bestSafeScore then
        local margin = num(selectedScore.total, 0) - num(bestSafeScore.total, 0)
        if margin >= num(ctx.cfg.CONTRACT_DECISIVE_NON_COMBAT_MARGIN or 1800, 1800) then
            proofReason = "combat_loses_decisive_material_and_no_draw_pressure"
        end
    end

    if contracts.conversionActive == true
        and selectedCandidate
        and selectedCandidate.hasFactionAttack ~= true
        and selectedCandidate.containsDeploy == true
        and bestNonDeployNonCombat
        and bestNonDeployNonCombat ~= selected then
        ctx.stats.passiveOverrideReason = "forced_nondeploy_conversion_progress"
        ctx.stats.passiveOverrideForbidden = false
        ctx.stats.combatSkippedWithProof = (ctx.stats.combatSkippedWithProof or 0) + 1
        return bestNonDeployNonCombat
    end

    if proofReason and ALLOWED_PASSIVE_PROOFS[proofReason] and forbiddenReason == nil then
        ctx.stats.combatSkippedWithProof = (ctx.stats.combatSkippedWithProof or 0) + 1
        ctx.stats.passiveOverrideReason = proofReason
        ctx.stats.passiveOverrideForbidden = false
        return selected
    end

    local forced = nil
    local forcedReason = nil
    if contracts.defenseActive then
        if bestDefense and bestDefense ~= selected and resolvesImmediateDefense(bestDefense) then
            forced = bestDefense
            forcedReason = "forced_defense_over_combat"
        end
        if (not forced) and bestSafeCombat and resolvesImmediateDefense(bestSafeCombat) then
            forced = bestSafeCombat
            forcedReason = "forced_defense_safe_combat"
        end
        if (not forced) and bestCombatAny and bestCombatAny ~= selected and resolvesImmediateDefense(bestCombatAny) then
            forced = bestCombatAny
            forcedReason = "forced_defense_safe_combat"
        end
        if (not forced) and bestNonCombat and bestNonCombat ~= selected and resolvesImmediateDefense(bestNonCombat) then
            forced = bestNonCombat
            forcedReason = "forced_defense_over_combat"
        end
    else
        if drawNearLimit and drawHasCombatAlternative then
            forced = bestHardCombat or bestSafeCombat or bestCombatAny
            forcedReason = "forced_draw_clock_interaction"
        elseif contracts.conversionActive == true
            and selectedCandidate
            and selectedCandidate.hasFactionAttack ~= true
            and selectedCandidate.containsDeploy == true
            and bestNonDeployNonCombat
            and bestNonDeployNonCombat ~= selected then
            forced = bestNonDeployNonCombat
            forcedReason = "forced_nondeploy_conversion_progress"
        else
            forced = bestHardCombat
        end
    end

    if forced then
        if forcedReason then
            ctx.stats.passiveOverrideReason = forcedReason
        elseif ctx.stats.passiveOverrideReason ~= "unsafe_combat_rejected_for_commandant_safety" then
            ctx.stats.passiveOverrideReason = "forced_best_safe_combat"
        end
        ctx.stats.passiveOverrideForbidden = false
        if forced.candidate and forced.candidate.hasFactionAttack == true then
            ctx.stats.combatSelected = (ctx.stats.combatSelected or 0) + 1
        else
            ctx.stats.combatSkippedWithProof = (ctx.stats.combatSkippedWithProof or 0) + 1
        end
        return forced
    end

    if contracts.defenseActive and selectedWinsNow ~= true and selectedDefendsImmediate ~= true then
        forbiddenReason = forbiddenReason or (
            contracts.defenseKind == "pressure"
                and "defend_now_unresolved_pressure"
                or "defend_now_unresolved_lethal"
        )
    end

    ctx.stats.combatSkippedWithoutProof = (ctx.stats.combatSkippedWithoutProof or 0) + 1
    ctx.stats.passiveOverrideReason = forbiddenReason or "missing_proof_no_safe_combat"
    ctx.stats.passiveOverrideForbidden = true
    return selected
end

function M.buildCoreTimeoutFloorItem(ai, state, ctx, contracts)
    if not (ai and state and ctx and ctx.cfg.CORE_TIMEOUT_FLOOR_ENABLED == true) then
        return nil
    end

    local originalShouldStop = ctx.shouldStop
    local originalSoftStop = ctx.softStop
    local originalHardStop = ctx.hardStop

    local function keepSearchingButYield()
        if ctx.yieldIfNeeded then
            ctx.yieldIfNeeded()
        end
        return false
    end
    ctx.shouldStop = keepSearchingButYield
    ctx.softStop = keepSearchingButYield
    ctx.hardStop = keepSearchingButYield

    local function buildRankedFloor()
        local maxCandidates = clampLimit(ctx.cfg.CORE_TIMEOUT_FLOOR_MAX_CANDIDATES or 24, 4, 72)
        local maxFirst = clampLimit(ctx.cfg.CORE_TIMEOUT_FLOOR_MAX_FIRST_ACTIONS or 12, 4, 36)
        local maxSecond = clampLimit(ctx.cfg.CORE_TIMEOUT_FLOOR_MAX_SECOND_ACTIONS or 8, 2, 24)
        local maxRanked = clampLimit(ctx.cfg.CORE_TIMEOUT_FLOOR_MAX_RANKED or 6, 1, 24)

        local candidates = ctx.turnEnumerator.generateFullTurnCandidates(ai, state, ctx.aiPlayer, ctx, {
            maxCandidates = maxCandidates,
            maxFirstActions = maxFirst,
            maxSecondActions = maxSecond,
            allowGuaranteedFallback = true
        }) or {}
        ctx.stats.coreTimeoutFloorCandidates = #candidates
        if #candidates == 0 then
            return {}
        end

        local ranked = rankCandidatePool(ai, state, ctx, candidates, {
            allowSoftStop = false,
            requiredLane = false,
            maxRanked = maxRanked,
            ignoreBudget = true,
            trackBestSoFar = false,
            laneName = "core_timeout_floor"
        })
        table.sort(ranked, function(a, b)
            return ctx.score.isBetter(a and a.fastScore or nil, b and b.fastScore or nil)
        end)
        return ranked
    end

    local ok = true
    local rankedOrError = nil
    if ctx.cooperative == true then
        rankedOrError = buildRankedFloor()
    else
        ok, rankedOrError = pcall(buildRankedFloor)
    end

    ctx.shouldStop = originalShouldStop
    ctx.softStop = originalSoftStop
    ctx.hardStop = originalHardStop

    if not ok then
        ctx.stats.coreTimeoutFloorError = tostring(rankedOrError)
        return nil
    end

    local ranked = rankedOrError or {}
    ctx.stats.coreTimeoutFloorUsed = true
    ctx.stats.coreTimeoutFloorRanked = #ranked
    for _, item in ipairs(ranked) do
        local allowed, rejectReason = M.coreTimeoutBestAllowed(ai, state, ctx, contracts, item)
        if allowed then
            ctx.stats.coreTimeoutFloorSelected = item.candidate and item.candidate.signature or nil
            M.updateCoreBestSoFar(ctx, item, "core_timeout_floor", {countEvaluation = false})
            return item
        end
        ctx.stats.coreTimeoutFloorRejected = num(ctx.stats.coreTimeoutFloorRejected, 0) + 1
        ctx.stats.coreTimeoutFloorRejectReason = rejectReason
    end
    ctx.stats.coreTimeoutFloorSelected = nil
    return nil
end

function M.buildContext(ai, state, opts)
    local options = opts or {}
    local cfg = ai:getTournamentConfig() or {}
    local aiPlayer = ai:getFactionId()
    local enemyPlayer = ai:getOpponentPlayer(aiPlayer)
    local aiIdentityReference = tostring(ai.aiReference or "base")
    local aiEffectiveReference = aiIdentityReference
    if ai.getEffectiveAiReference then
        local ok, value = pcall(ai.getEffectiveAiReference, ai, state, {
            factionId = aiPlayer
        })
        if ok and value then
            aiEffectiveReference = tostring(value)
        end
    end

    local softBudget = options.softBudgetMs
        or (ai.getTournamentBudgetMs and ai:getTournamentBudgetMs("SOFT_BUDGET_MS", 450))
        or (cfg.SOFT_BUDGET_MS or 450)
    local hardBudget = options.hardBudgetMs
        or (ai.getTournamentBudgetMs and ai:getTournamentBudgetMs("HARD_BUDGET_MS", 500))
        or (cfg.HARD_BUDGET_MS or 500)

    local ctx = {
        selfAI = ai,
        cfg = cfg,
        policy = "tournament_prime",
        ignoreProfileOverrides = cfg.IGNORE_PROFILE_OVERRIDES == true,
        profileReference = "tournament_prime",
        aiReference = aiIdentityReference,
        aiEffectiveReference = aiEffectiveReference,
        aiIdentityReference = aiIdentityReference,
        aiPlayer = aiPlayer,
        enemyPlayer = enemyPlayer,
        currentState = state,
        maxActions = options.maxActions or 2,
        decisionStartTime = options.decisionStartTime,
        budgetElapsedMs = options.budgetElapsedMs,
        cooperative = options.cooperative == true,
        shouldYield = options.shouldYield,
        softBudgetMs = softBudget,
        hardBudgetMs = hardBudget,
        score = score,
        tacticalGate = tacticalGate,
        turnEnumerator = turnEnumerator,
        candidateBuckets = candidateBuckets,
        supplyPlanner = supplyPlanner,
        reserveModel = reserveModel,
        evaluator = evaluator,
        responseModel = responseModel,
        threatModel = threatModel,
        tacticalExtension = tacticalExtension,
        earlyPlanner = earlyPlanner,
        stats = {
            phase = nil,
            phaseTurn = nil,
            phaseReason = nil,
            phaseEarlyMax = nil,
            phaseEarlyReference = nil,
            aiReference = aiIdentityReference,
            aiEffectiveReference = aiEffectiveReference,
            aiIdentityReference = aiIdentityReference,
            earlyPlanActive = false,
            earlyRole = nil,
            earlyIntent = nil,
            earlyConfidence = 0,
            earlyFocalLane = nil,
            earlySupportLane = nil,
            earlyDesiredRoles = nil,
            earlyPlanReasons = nil,
            earlyFormationScore = 0,
            earlyFormationReasons = nil,
            tacticalOverrideReason = nil,
            earlyAttackCommitmentReason = nil,
            earlyAttackCommitmentRejected = false,
            earlyAttackCommitmentReplacement = nil,
            earlyAttackCommitmentMaterialGain = 0,
            earlyAttackCommitmentBoardDelta = 0,
            earlyDiagnosticsEnabled = false,
            pipelineV2MidEnabled = false,
            pipelineV2MidAttempted = false,
            pipelineV2MidSkipped = false,
            pipelineV2MidSkippedReason = nil,
            pipelineV2MidFailedReason = nil,
            pipelineV2MidFellThroughToTournament = false,
            pipelineV2MidCandidates = 0,
            pipelineV2MidAttackCandidates = 0,
            pipelineV2MidPositionCandidates = 0,
            pipelineV2MidFinalists = 0,
            pipelineV2MidGateExtraMs = 0,
            pipelineV2MidRemainingBeforeGateMs = 0,
            pipelineV2MidGateEvaluated = 0,
            pipelineV2MidAccepted = 0,
            pipelineV2MidGateSkippedByBudget = false,
            pipelineV2MidPrepared = 0,
            pipelineV2MidRecoveredBestCandidate = false,
            pipelineV2MidRecoveredFromReason = nil,
            pipelineV2MidRecoveredGateRejectReason = nil,
            pipelineV2MidBestRecoveryRejected = nil,
            pipelineV2FinalistsExtraMs = 0,
            pipelineV2RemainingBeforeFinalistsMs = 0,
            pipelineV2FinalistsEvaluated = 0,
            pipelineV2FinalistsSkippedByBudget = false,
            earlyDiagSource = nil,
            earlyDiagFirstRankMode = nil,
            earlyDiagFirstLegalActions = 0,
            earlyDiagFirstBeamSelected = 0,
            earlyDiagFirstBeamCap = 0,
            earlyDiagSecondBeamCap = 0,
            earlyDiagCandidateCap = 0,
            earlyDiagSecondStates = 0,
            earlyDiagSecondLegalActionsTotal = 0,
            earlyDiagSecondLegalActionsMax = 0,
            earlyDiagSecondBeamSelectedTotal = 0,
            earlyDiagSecondBeamSelectedMax = 0,
            earlyDiagFullCandidatesGeneratedBeforeFallback = 0,
            earlyDiagFullCandidatesReturned = 0,
            earlyDiagNormalRankedBeforeGate = 0,
            earlyDiagNormalGateKept = 0,
            earlyDiagAuditEnabled = false,
            earlyDiagAuditCandidates = 0,
            earlyDiagAuditRanked = 0,
            earlyDiagAuditGateOriginal = 0,
            earlyDiagAuditGateKept = 0,
            earlyDiagAuditGateRejected = 0,
            earlyDiagAuditGateStoppedByBudget = false,
            earlyDiagAuditFoundGateKept = false,
            earlyDiagAuditGateKeptOutsideNormal = 0,
            earlyDiagAuditFirstReason = nil,
            earlyDiagAuditReasonCounts = {},
            earlyDiagAuditMs = 0,
            earlyDiagAuditError = nil,
            earlyProductiveEnumerationEnabled = false,
            earlyProductiveFirstPrepared = 0,
            earlyProductiveFirstShortlisted = 0,
            earlyProductiveFirstSelected = 0,
            ownCandidates = 0,
            ranked = 0,
            finalists = 0,
            evaluatedCandidates = 0,
            bestSoFarAvailable = false,
            bestSoFarSource = nil,
            bestSoFarSignature = nil,
            bestSoFarScore = 0,
            coreExit = nil,
            fallbackSource = nil,
            sanitizerCandidateAttempts = 0,
            sanitizerCandidateRejected = 0,
            sanitizerAlternativeAccepted = nil,
            sanitizerAlternativeAcceptedAfterAttempts = 0,
            sanitizerAlternativePool = 0,
            replyEvaluations = 0,
            extensionEvaluations = 0,
            forcedFiltered = false,
            timeout = false,
            cacheHits = 0,
            cacheMisses = 0,
            cacheSimulationHits = 0,
            cacheSimulationMisses = 0,
            cacheFeatureHits = 0,
            cacheFeatureMisses = 0,
            cacheLegalHits = 0,
            cacheLegalMisses = 0,
            cacheThreatHits = 0,
            cacheThreatMisses = 0,
            cacheSupplyHits = 0,
            cacheSupplyMisses = 0,
            cacheExtensionHits = 0,
            cacheExtensionMisses = 0,
            enemyDeployReplies = 0,
            ownDeployCandidates = 0,
            ownSupplyCount = 0,
            enemySupplyCount = 0,
            normalFullTurnTechnicalOnly = false,
            normalFullTurnSkipped = false,
            normalFullTurnCandidates = 0,
            normalFullTurnRanked = 0,
            deployCandidatesOwn = 0,
            deployCandidatesEnemy = 0,
            enemyReplyDeployCandidates = 0,
            enemyReplyBatches = 0,
            enemyReplyCandidatesGenerated = 0,
            enemyReplyCandidatesGeneratedMax = 0,
            enemyReplyCandidatesSelected = 0,
            enemyReplyScoredForSort = 0,
            enemyReplyScoredWorst = 0,
            enemyReplySortStoppedByBudget = 0,
            enemyReplyWorstStoppedByBudget = 0,
            enemyReplyFirstActionPoolTotal = 0,
            enemyReplyFirstActionPoolMax = 0,
            enemyReplySecondActionStates = 0,
            enemyReplySecondActionPoolTotal = 0,
            enemyReplySecondActionPoolMax = 0,
            enemyReplyCacheHits = 0,
            enemyReplyCacheMisses = 0,
            enemyReplyTacticalExtensionChecks = 0,
            enemyReplyTacticalExtensionUsed = 0,
            replyQuestionCounts = {},
            replyOutcomeCounts = {},
            replyUsefulEvaluations = 0,
            replyNoScoreEvaluations = 0,
            replyCheapSafetyEvaluations = 0,
            extensionQuestionCounts = {},
            extensionOutcomeCounts = {},
            extensionCandidates = 0,
            extensionProofs = 0,
            extensionRefutations = 0,
            extensionTimeouts = 0,
            replySkippedByBudget = 0,
            extensionSkippedByBudget = 0,
            stageMs = {},
            legalAttackActions = 0,
            legalMoveAttackActions = 0,
            candidateWithFactionAttack = 0,
            rankedWithFactionAttack = 0,
            finalistWithFactionAttack = 0,
            rankedSourceCountsBeforeGate = {},
            rankedSourceCountsAfterGate = {},
            finalistSourceCounts = {},
            selectedHasFactionAttack = false,
            selectedPassiveOnly = false,
            selectedFastScore = nil,
            selectedFinalScore = nil,
            selectedScoreDelta = 0,
            selectedCandidateSource = nil,
            selectedCandidateLane = nil,
            selectedRequiredLane = false,
            selectedEarlyPositionReason = nil,
            selectedEarlyPositionTarget = nil,
            selectedContainsDeploy = false,
            selectedContainsAttack = false,
            selectedReplyQuestion = nil,
            selectedReplyOutcome = nil,
            selectedExtensionQuestion = nil,
            selectedExtensionOutcome = nil,
            selectedMatchesBestSoFar = false,
            preSanitizeSelectedStage = nil,
            preSanitizeSelectedSignature = nil,
            preSanitizeCandidateSource = nil,
            preSanitizeCandidateLane = nil,
            preSanitizeRequiredLane = false,
            preSanitizeEarlyPositionReason = nil,
            preSanitizeEarlyPositionTarget = nil,
            preSanitizeContainsDeploy = false,
            preSanitizeContainsAttack = false,
            preSanitizeFastScore = nil,
            preSanitizeFinalScore = nil,
            preSanitizeScoreDelta = 0,
            preSanitizeReplyQuestion = nil,
            preSanitizeReplyOutcome = nil,
            preSanitizeExtensionQuestion = nil,
            preSanitizeExtensionOutcome = nil,
            preSanitizeMatchesBestSoFar = false,
            bestFactionAttackFastScore = nil,
            attackLossReason = nil,
            combatContractActive = false,
            combatDirectGenerated = 0,
            combatDirectGenerationAttempts = 0,
            combatMoveAttackGenerated = 0,
            combatGeneratedTotal = 0,
            combatExplicitSanitizeAttempts = 0,
            combatExplicitSanitizeRejected = 0,
            combatRanked = 0,
            combatFinalists = 0,
            combatSelected = 0,
            combatSkippedWithProof = 0,
            combatSkippedWithoutProof = 0,
            combatSafeRanked = 0,
            safeCombatAvailable = false,
            bestSafeCombatClass = nil,
            bestSafeCombatSignature = nil,
            bestSafeCombatDamage = 0,
            bestSafeCombatKills = 0,
            bestSafeCombatTargetValue = 0,
            passiveOverrideReason = nil,
            passiveOverrideForbidden = false,
            selectedFactionAttackCount = 0,
            selectedMeleeFactionAttackCount = 0,
            selectedRangedFactionAttackCount = 0,
            selectedCombatClass = nil,
            selectedCommandantDamage = 0,
            selectedKillCount = 0,
            selectedCreatesNextTurnCommandantLethal = false,
            selectedRemovesEnemyLastAttacker = false,
            drawConversionOpportunity = false,
            drawConversionChosen = false,
            drawConversionMissReason = nil,
            conversionContractActive = false,
            conversionContracts = {},
            conversionMaterialDiff = 0,
            conversionOwnUnits = 0,
            conversionEnemyUnits = 0,
            conversionOwnHubHp = 0,
            conversionEnemyHubHp = 0,
            conversionCommandantPressure = 0,
            conversionForcingChecks = 0,
            conversionForcingSignals = 0,
            kernelAvailable = false,
            kernelReason = nil,
            kernelSource = nil,
            selectedContract = nil,
            defenseRaceTTD = -1,
            defenseRaceTTW = -1,
            defenseRaceWinRaceEstimate = false,
            defenseRaceRejectedByWinRace = false,
            defenseRaceProof = nil,
            defenseRaceBestETA = nil,
            defenseRaceLineBlock = false,
            defenseRaceUnresolvedReason = nil,
            moveThreatAttackActions = 0,
            cooperativeYields = 0
        }
    }

    ctx.cache = cacheModule.new(ctx)

    function ctx.elapsedMs()
        if ctx.budgetElapsedMs then
            return ctx.budgetElapsedMs()
        end
        if ctx.decisionStartTime and love and love.timer and love.timer.getTime then
            return (love.timer.getTime() - ctx.decisionStartTime) * 1000
        end
        if ctx._fallbackStartMs == nil then
            ctx._fallbackStartMs = nowMs()
        end
        return nowMs() - ctx._fallbackStartMs
    end

    function ctx.softStop()
        ctx.yieldIfNeeded()
        return ctx.elapsedMs() >= ctx.softBudgetMs
    end

    function ctx.hardStop()
        ctx.yieldIfNeeded()
        return ctx.elapsedMs() >= ctx.hardBudgetMs
    end

    function ctx.remainingMs()
        ctx.yieldIfNeeded()
        return math.max(0, num(ctx.hardBudgetMs, 0) - num(ctx.elapsedMs(), 0))
    end

    function ctx.pushDeadline(deltaMs)
        local limitMs = math.max(0, num(deltaMs, 0))
        local stack = ctx._deadlineStack or {}
        stack[#stack + 1] = ctx.elapsedMs() + limitMs
        ctx._deadlineStack = stack
    end

    function ctx.popDeadline()
        local stack = ctx._deadlineStack or {}
        if #stack > 0 then
            table.remove(stack)
        end
        ctx._deadlineStack = stack
    end

    function ctx.yieldIfNeeded()
        if ctx.cooperative
            and ctx.shouldYield
            and ctx.shouldYield()
            and coroutine
            and coroutine.running
            and coroutine.running() then
            ctx.stats.cooperativeYields = num(ctx.stats.cooperativeYields, 0) + 1
            coroutine.yield("ai_decision_slice")
        end
    end

    function ctx.shouldStop()
        ctx.yieldIfNeeded()
        if ctx.hardStop() then
            return true
        end
        local stack = ctx._deadlineStack or {}
        if #stack > 0 then
            return ctx.elapsedMs() >= num(stack[#stack], 0)
        end
        return false
    end

    function ctx.beginStage(name)
        if not name then
            return
        end
        local stack = ctx._stageStack or {}
        if #stack == 0 then
            ctx._stageRootStartedMs = ctx.elapsedMs()
        end
        stack[#stack + 1] = {
            name = name,
            startedMs = ctx.elapsedMs()
        }
        ctx._stageStack = stack
    end

    function ctx.endStage(name)
        local stack = ctx._stageStack or {}
        if #stack == 0 then
            return
        end

        local frame = nil
        if not name then
            frame = table.remove(stack)
        else
            for i = #stack, 1, -1 do
                if stack[i].name == name then
                    frame = stack[i]
                    table.remove(stack, i)
                    break
                end
            end
            if not frame then
                return
            end
        end

        local delta = math.max(0, ctx.elapsedMs() - num(frame.startedMs, 0))
        local stageName = tostring(frame.name or "unknown")
        local stageMs = ctx.stats.stageMs or {}
        stageMs[stageName] = num(stageMs[stageName], 0) + delta
        ctx.stats.stageMs = stageMs
        if #stack == 0 and ctx._stageRootStartedMs ~= nil then
            ctx._stageRootMeasuredMs =
                num(ctx._stageRootMeasuredMs, 0) + math.max(0, ctx.elapsedMs() - num(ctx._stageRootStartedMs, 0))
            ctx._stageRootStartedMs = nil
        end
        ctx._stageStack = stack
    end

    function ctx.profileStage(name, fn)
        if not fn then
            return nil
        end
        local stageName = tostring(name or "")
        local stageDeadlineMs = nil
        if stageName:find("repair", 1, true) or stageName:find("alternative", 1, true) then
            stageDeadlineMs = clampLimit(ctx.cfg.EARLY_GATE_ALTERNATIVE_MAX_MS or 70, 20, 160)
            ctx.pushDeadline(stageDeadlineMs)
        end
        ctx.beginStage(name)
        if ctx.cooperative == true then
            local a, b, c, d, e, f = fn()
            ctx.endStage(name)
            if stageDeadlineMs then
                ctx.popDeadline()
            end
            return a, b, c, d, e, f
        end
        local ok, a, b, c, d, e, f = pcall(fn)
        ctx.endStage(name)
        if stageDeadlineMs then
            ctx.popDeadline()
        end
        if not ok then
            error(a, 0)
        end
        return a, b, c, d, e, f
    end

    ctx.supply = ctx.profileStage("context_supply", function()
        return {
            own = reserveModel.snapshotSupplyForPlayer(ai, state, aiPlayer, ctx),
            enemy = reserveModel.snapshotSupplyForPlayer(ai, state, enemyPlayer, ctx)
        }
    end)
    ctx.stats.ownSupplyCount = num(ctx.supply.own and ctx.supply.own.count, 0)
    ctx.stats.enemySupplyCount = num(ctx.supply.enemy and ctx.supply.enemy.count, 0)
    ctx.phase = ctx.profileStage("context_phase", function()
        return earlyPlanner.detectPhase(ai, state, ctx)
    end)
    ctx.stats.phase = ctx.phase and ctx.phase.name or nil
    ctx.stats.phaseTurn = ctx.phase and ctx.phase.turn or nil
    ctx.stats.phaseReason = ctx.phase and ctx.phase.reason or nil
    ctx.stats.phaseEarlyMax = ctx.phase and ctx.phase.earlyMax or nil
    ctx.stats.phaseEarlyReference = ctx.phase and ctx.phase.earlyReference or nil
    ctx.stats.phaseEndgame = ctx.phase and ctx.phase.endgame == true or false
    ctx.earlyPlan = ctx.profileStage("context_early_plan", function()
        return earlyPlanner.build(ai, state, ctx)
    end)
    if ctx.earlyPlan then
        ctx.stats.earlyPlanActive = ctx.earlyPlan.active == true
        ctx.stats.earlyRole = ctx.earlyPlan.role
        ctx.stats.earlyIntent = ctx.earlyPlan.intent
        ctx.stats.earlyConfidence = num(ctx.earlyPlan.confidence, 0)
        ctx.stats.earlyFocalLane = ctx.earlyPlan.focalLane
        ctx.stats.earlySupportLane = ctx.earlyPlan.supportLane
        ctx.stats.earlyDesiredRoles = copyMap(ctx.earlyPlan.desiredRoles or {})
        ctx.stats.earlyPlanReasons = copyArray(ctx.earlyPlan.reasons or {})
    end

    return ctx
end

function M.chooseTurn(ai, state, opts)
    local ctx = M.buildContext(ai, state, opts or {})
    local meta = {
        source = "tournament",
        reason = nil,
        fallbackReason = nil,
        stats = ctx.stats,
        contract = nil,
        contractEvidence = nil
    }

    if not state or not state.units or not ctx.aiPlayer then
        meta.reason = "invalid_state"
        meta.contract = CONTRACTS.TECHNICAL_FALLBACK
        finalizeMeta(meta, ctx, state)
        return nil, meta
    end

    local drawUrgency = ctx.profileStage("draw_urgency", function()
        return ctx.evaluator
            and ctx.evaluator.getOfficialDrawUrgency
            and ctx.evaluator.getOfficialDrawUrgency(ai, state)
    end)

    ctx.stats.drawStreak = num(drawUrgency and drawUrgency.streak, num(state and state.turnsWithoutDamage, 0))
    ctx.stats.officialDrawUrgencyActive = drawUrgency and drawUrgency.active == true
    ctx.stats.officialDrawUrgency = num(drawUrgency and drawUrgency.urgency, 0)
    ctx.stats.officialDrawUrgencyMax = num(drawUrgency and drawUrgency.urgencyMax, nil)
    ctx.stats.officialDrawCountFromFullTurn = num(drawUrgency and drawUrgency.countFromFullTurn, nil)
    ctx.stats.officialDrawNoInteractionLimit = num(drawUrgency and drawUrgency.noInteractionLimit, nil)
    ctx.stats.officialDrawPressureLimit = drawUrgency and drawUrgency.pressureLimit == true
    ctx.stats.officialDrawPressureStreak = num(drawUrgency and drawUrgency.pressureStreak, nil)
    ctx.stats.officialDrawNearLimit = drawUrgency and drawUrgency.nearLimit == true
    ctx.stats.officialDrawCriticalLimit = drawUrgency and drawUrgency.criticalLimit == true
    ctx.stats.officialDrawNearStreak = num(drawUrgency and drawUrgency.nearStreak, nil)
    ctx.stats.officialDrawCriticalStreak = num(drawUrgency and drawUrgency.criticalStreak, nil)

    ctx.stats.legalAttackActions = ctx.profileStage("legal_attack_count", function()
        return countLegalFactionAttackActions(ai, state, ctx.aiPlayer, ctx.evaluator, ctx)
    end)
    ctx.stats.legalMoveAttackActions = ctx.profileStage("legal_move_attack_count", function()
        return countLegalMoveAttackFactionAttacks(ai, state, ctx.aiPlayer, ctx)
    end)

    local immediateWin = nil
    local sanitizedImmediate = nil
    local immediateWinSanitizeSummary = nil
    withHardStageBudget(ctx, "immediate_win", "HARD_IMMEDIATE_WIN_EXTRA_MS", function()
        ctx.beginStage("immediate_win")
        immediateWin = ctx.tacticalGate.findImmediateWin(ai, state, ctx)
        if immediateWin and immediateWin.candidate then
            immediateWin.candidate = annotateCandidateDiagnostics(ctx.evaluator, state, immediateWin.candidate, ctx.aiPlayer)
            sanitizedImmediate, immediateWinSanitizeSummary = sanitizeTournamentSequenceForContext(
                ai,
                state,
                immediateWin.candidate.actions,
                ctx,
                {requireExact = true}
            )
        end
        ctx.endStage("immediate_win")
    end)

    if immediateWin and immediateWin.candidate then
        if sanitizedImmediate and #sanitizedImmediate > 0 then
            immediateWin.candidate.actions = sanitizedImmediate
            immediateWin.candidate.signature = ctx.turnEnumerator.sequenceSignature(sanitizedImmediate)
            immediateWin.candidate.sanitizerOk = true
            ctx.stats.hardSelectionLocked = true
            ctx.stats.hardSelectionReason = "win_now"
            ctx.stats.hardSelectionSignature = immediateWin.candidate.signature
            meta.reason = "immediate_win"
            meta.selected = immediateWin
            meta.contract = CONTRACTS.WIN_NOW
            meta.contractEvidence = {
                activeContracts = {CONTRACTS.WIN_NOW},
                legalDirectFactionAttacks = ctx.stats.legalAttackActions,
                legalMoveAttackFactionAttacks = ctx.stats.legalMoveAttackActions,
                officialDrawStreak = ctx.stats.drawStreak,
                selectedProofReason = nil,
                passiveOverride = nil
            }
            ctx.stats.ownCandidates = 1
            markSelectedDiagnostics(ai, ctx, state, immediateWin)
            finalizeMeta(meta, ctx, state)
            return immediateWin.candidate.actions, meta
        end

        ctx.stats.invalidImmediateWinCandidate = (ctx.stats.invalidImmediateWinCandidate or 0) + 1
        ctx.stats.hardSelectionRejected = true
        ctx.stats.hardSelectionReason = "win_now"
        ctx.stats.hardSelectionRejectReason = "immediate_win_sanitize_rejected"
        ctx.stats.hardSelectionRejectStage = "tournament_sanitizer"
        ctx.stats.hardSelectionRejectSignature = immediateWin.candidate.signature
        ctx.stats.hardSelectionRejectSanitizerReplacements =
            num(immediateWinSanitizeSummary and immediateWinSanitizeSummary.replacements, 0)
        ctx.stats.hardSelectionRejectSanitizerReasonCounts =
            copyMap(immediateWinSanitizeSummary and immediateWinSanitizeSummary.reasonCounts or {})
        ctx.stats.immediateWinSanitizerReplacements =
            num(immediateWinSanitizeSummary and immediateWinSanitizeSummary.replacements, 0)
    end

    local hardWinSelection = nil
    local hardWinItem = nil
    local hardWinSanitizeSummary = nil
    local hardWinRejectReason = nil
    withHardStageBudget(ctx, "hard_win", "HARD_WIN_EXTRA_MS", function()
        ctx.beginStage("hard_win")
        hardWinSelection = require("ai_tournament.hard_win").select(ai, state, ctx)
        if hardWinSelection then
            hardWinItem, hardWinSanitizeSummary, hardWinRejectReason =
                M._materializeHardWinSelection(ai, state, ctx, hardWinSelection)
        end
        ctx.endStage("hard_win")
    end)
    if hardWinSelection then
        if hardWinItem and hardWinItem.candidate and hardWinItem.candidate.actions then
            meta.reason = hardWinSelection.reason or "hard_win_priority00"
            meta.selected = hardWinItem
            meta.contract = CONTRACTS.WIN_NOW
            ctx.stats.coreExit = "hard_win"
            ctx.stats.fallbackSource = nil
            ctx.stats.hardSelectionLocked = true
            ctx.stats.hardSelectionReason = "win_now"
            ctx.stats.hardSelectionSignature = hardWinItem.candidate.signature
            ctx.stats.hardWinPriority00SelectedSignature = hardWinItem.candidate.signature
            ctx.stats.hardWinPriority00SelectedKind = hardWinSelection.kind
            ctx.stats.hardWinPriority00SelectedProof = hardWinSelection.proof
            ctx.stats.sanitizerReplacements = num(hardWinSanitizeSummary and hardWinSanitizeSummary.replacements, 0)
            ctx.stats.sanitizerReasonCounts =
                copyMap(hardWinSanitizeSummary and hardWinSanitizeSummary.reasonCounts or {})
            meta.contractEvidence = {
                activeContracts = {CONTRACTS.WIN_NOW},
                legalDirectFactionAttacks = ctx.stats.legalAttackActions,
                legalMoveAttackFactionAttacks = ctx.stats.legalMoveAttackActions,
                officialDrawStreak = ctx.stats.drawStreak,
                selectedProofReason = hardWinSelection.proof or "win_now",
                passiveOverride = nil
            }
            markSelectedDiagnostics(ai, ctx, state, hardWinItem)
            finalizeMeta(meta, ctx, state)
            return hardWinItem.candidate.actions, meta
        end
        ctx.stats.hardWinPriority00Rejected = hardWinRejectReason or "hard_win_rejected"
        ctx.stats.hardWinPriority00RejectedSanitizerReplacements =
            num(hardWinSanitizeSummary and hardWinSanitizeSummary.replacements, 0)
        ctx.stats.hardWinPriority00RejectedSanitizerReasonCounts =
            copyMap(hardWinSanitizeSummary and hardWinSanitizeSummary.reasonCounts or {})
    end

    ctx.beginStage("contract_detect")
    local baseThreat = ctx.tacticalGate.detectImmediateThreat(ai, state, ctx.aiPlayer, ctx.enemyPlayer, ctx)
    local contracts = detectActiveContracts(
        ai,
        state,
        ctx,
        baseThreat,
        drawUrgency,
        ctx.stats.legalAttackActions,
        ctx.stats.legalMoveAttackActions
    )
    ctx.endStage("contract_detect")
    ctx.activeContracts = contracts
    if ctx.stats then
        ctx.stats.earlyPlanSuppressedByDefense = ctx.earlyPlan
            and ctx.earlyPlan.active == true
            and require("ai_tournament.defense_pressure_scope").isHardDefense(contracts)
            or false
    end
    ctx.stats.activeContracts = copyArray(contracts.activeNames or {})
    ctx.stats.defenseKind = contracts.defenseKind
    ctx.stats.commandantPressureDefenseActive = contracts.defenseKind == "pressure"
    ctx.stats.directThreatAttackActions = num(contracts.directThreatAttackActions, 0)
    ctx.stats.directThreatReductionActions = num(contracts.directThreatReductionActions, 0)
    ctx.stats.moveThreatAttackActions = num(contracts.moveThreatAttackActions, 0)
    ctx.stats.ownCommandantProjectedThreatDamage = threatProjectedDamage(contracts.defenseThreat)
    ctx.stats.defenseRaceTTD = finiteNumberOrNil(contracts.defenseRaceTTD) or -1
    ctx.stats.defenseRaceTTW = finiteNumberOrNil(contracts.defenseRaceTTW) or -1
    ctx.stats.defenseRaceWinRaceEstimate = contracts.defenseRaceWinRaceEstimate == true
    ctx.stats.defenseRaceRejectedByWinRace = false
    ctx.stats.defenseRaceProof = nil
    ctx.stats.defenseRaceBestETA = nil
    ctx.stats.defenseRaceLineBlock = false
    ctx.stats.conversionContractActive = contracts.conversionActive == true
    ctx.stats.conversionContracts = {
        convertWinningPosition = contracts.convertWinningPosition == true,
        breakDrawClock = contracts.breakDrawClock == true,
        forceCommandantPressure = contracts.forceCommandantPressure == true,
        eliminateLowHpUnit = contracts.eliminateLowHpUnit == true
    }
    ctx.stats.conversionMaterialDiff = num(contracts.conversionFeatures and contracts.conversionFeatures.materialDiff, 0)
    ctx.stats.conversionOwnUnits = num(contracts.conversionFeatures and contracts.conversionFeatures.ownUnitCount, 0)
    ctx.stats.conversionEnemyUnits = num(contracts.conversionFeatures and contracts.conversionFeatures.enemyUnitCount, 0)
    ctx.stats.conversionOwnHubHp = num(contracts.conversionFeatures and contracts.conversionFeatures.ownHubHp, 0)
    ctx.stats.conversionEnemyHubHp = num(contracts.conversionFeatures and contracts.conversionFeatures.enemyHubHp, 0)
    ctx.stats.conversionCommandantPressure = num(contracts.conversionFeatures and contracts.conversionFeatures.commandantPressure, 0)

    meta.contractEvidence = contracts.evidence

    ctx.stats.kernelAvailable = false
    ctx.stats.kernelReason = nil
    ctx.stats.kernelSource = nil

    local hardPunishSelection = nil
    local hardPunishItem = nil
    local hardPunishSanitizeSummary = nil
    local hardPunishRejectReason = nil
    withHardStageBudget(ctx, "hard_punish", "HARD_PUNISH_EXTRA_MS", function()
        ctx.beginStage("hard_punish")
        hardPunishSelection = require("ai_tournament.hard_punish").select(ai, state, ctx, contracts)
        if hardPunishSelection then
            hardPunishItem, hardPunishSanitizeSummary, hardPunishRejectReason =
                M._materializeHardPunishSelection(ai, state, ctx, contracts, hardPunishSelection)
        end
        ctx.endStage("hard_punish")
    end)
    if hardPunishSelection then
        if hardPunishItem and hardPunishItem.candidate and hardPunishItem.candidate.actions then
            local hardReason = (hardPunishSelection.kind == "ranged_commandant_pressure"
                or hardPunishSelection.kind == "move_ranged_commandant_pressure")
                and "safe_commandant_pressure"
                or "safe_kill"
            if hardPunishSelection.defensePressureResolved == true then
                hardReason = "defend_now_safe_kill"
            end
            meta.reason = hardPunishSelection.reason or "hard_punish_safe_kill"
            meta.selected = hardPunishItem
            ctx.stats.coreExit = "hard_punish"
            ctx.stats.fallbackSource = nil
            ctx.stats.hardSelectionLocked = true
            ctx.stats.hardSelectionReason = hardReason
            ctx.stats.hardSelectionSignature = hardPunishItem.candidate.signature
            ctx.stats.hardPunishSelectedSignature = hardPunishItem.candidate.signature
            ctx.stats.hardPunishSelectedKind = hardPunishSelection.kind
            ctx.stats.hardPunishSelectedProof = hardPunishSelection.proof
            ctx.stats.sanitizerReplacements = num(hardPunishSanitizeSummary and hardPunishSanitizeSummary.replacements, 0)
            ctx.stats.sanitizerReasonCounts =
                copyMap(hardPunishSanitizeSummary and hardPunishSanitizeSummary.reasonCounts or {})
            markSelectedDiagnostics(ai, ctx, state, hardPunishItem)
            ctx.stats.attackLossReason = computeAttackLossReason(ctx, hardPunishItem, hardPunishItem, hardPunishItem)
            local selectedContract = determineSelectedContract(ctx, contracts, hardPunishItem)
            ctx.stats.selectedContract = selectedContract
            meta.contract = selectedContract
            if contracts.evidence then
                contracts.evidence.selectedProofReason = hardReason
                contracts.evidence.passiveOverride = contracts.evidence.passiveOverride or {}
                contracts.evidence.passiveOverride.allowed = true
                contracts.evidence.passiveOverride.reason = hardReason
                contracts.evidence.passiveOverride.selectedSignature =
                    hardPunishItem.candidate and hardPunishItem.candidate.signature or nil
            end
            meta.contractEvidence = contracts.evidence
            finalizeMeta(meta, ctx, state)
            return hardPunishItem.candidate.actions, meta
        end
        ctx.stats.hardPunishRejected = hardPunishRejectReason or "hard_punish_rejected"
        ctx.stats.hardPunishRejectedSanitizerReplacements =
            num(hardPunishSanitizeSummary and hardPunishSanitizeSummary.replacements, 0)
        ctx.stats.hardPunishRejectedSanitizerReasonCounts =
            copyMap(hardPunishSanitizeSummary and hardPunishSanitizeSummary.reasonCounts or {})
    end

    local hardDefenseRecoveryReason = nil
    if defenseScope.isHardDefense(contracts) then
        ctx.stats.pipelineV2Skipped = true
        ctx.stats.pipelineV2FailedReason = "hard_defense_contract"
        local defenseLane = nil
        local rankedDefense = {}
        local selectedDefense = nil
        local defenseSanitizeSummary = nil
        local emergencyDefenseRejectReason = nil

        withHardStageBudget(ctx, "hard_defense_lane", "HARD_DEFENSE_EXTRA_MS", function()
            ctx.beginStage("hard_defense_lane")
            defenseLane = buildDefenseLane(ai, state, ctx, baseThreat)
            if defenseLane and #(defenseLane.candidates or {}) > 0 then
                rankedDefense = rankCandidatePool(ai, state, ctx, defenseLane.candidates, {
                    laneName = defenseLane.name,
                    requiredLane = true,
                    minimumRanked = defenseLane.minimumRanked,
                    maxRanked = clampLimit(ctx.cfg.CONTRACT_REQUIRED_LANE_RANK_CAP or 10, 1, 24),
                    allowSoftStop = false,
                    stopAfterMinimum = false
                })
            end

            for _, item in ipairs(rankedDefense or {}) do
                local sanitized, summary = chooseBestSanitizedSelection(ai, state, ctx, item, {item})
                defenseSanitizeSummary = summary or defenseSanitizeSummary
                if sanitized and M.hardLockReasonForSelection(ai, state, ctx, contracts, sanitized) == "defend_now" then
                    selectedDefense = sanitized
                    break
                end
            end

            if not selectedDefense then
                selectedDefense, defenseSanitizeSummary, emergencyDefenseRejectReason =
                    selectEmergencyDefenseFallback(
                        ai,
                        state,
                        ctx,
                        contracts,
                        baseThreat,
                        defenseLane and defenseLane.emergencyCandidate or nil
                    )
            end
            ctx.endStage("hard_defense_lane")
        end)
        ctx.stats.hardDefenseCandidates = defenseLane and #(defenseLane.candidates or {}) or 0
        ctx.stats.hardDefenseRanked = #rankedDefense

        if selectedDefense and selectedDefense.candidate and selectedDefense.candidate.actions then
            meta.reason = "hard_defense_contract"
            meta.selected = selectedDefense
            meta.contract = CONTRACTS.DEFEND_NOW
            ctx.stats.coreExit = "hard_defense"
            ctx.stats.fallbackSource = nil
            ctx.stats.hardSelectionLocked = true
            ctx.stats.hardSelectionReason = "defend_now"
            ctx.stats.hardSelectionSignature = selectedDefense.candidate.signature
            ctx.stats.hardDefenseSelectedSignature = selectedDefense.candidate.signature
            ctx.stats.sanitizerReplacements = num(defenseSanitizeSummary and defenseSanitizeSummary.replacements, 0)
            ctx.stats.sanitizerReasonCounts =
                copyMap(defenseSanitizeSummary and defenseSanitizeSummary.reasonCounts or {})
            markSelectedDiagnostics(ai, ctx, state, selectedDefense)
            ctx.stats.attackLossReason = computeAttackLossReason(ctx, selectedDefense, nil, nil)
            ctx.stats.selectedContract = CONTRACTS.DEFEND_NOW
            if contracts.evidence then
                contracts.evidence.selectedProofReason = "defend_now"
                contracts.evidence.passiveOverride = contracts.evidence.passiveOverride or {}
                contracts.evidence.passiveOverride.allowed = true
                contracts.evidence.passiveOverride.reason = "defend_now"
                contracts.evidence.passiveOverride.selectedSignature =
                    selectedDefense.candidate and selectedDefense.candidate.signature or nil
            end
            meta.contractEvidence = contracts.evidence
            finalizeMeta(meta, ctx, state)
            return selectedDefense.candidate.actions, meta
        end

        ctx.stats.hardDefenseRejected = emergencyDefenseRejectReason or "no_sanitized_defense_candidate"
        ctx.stats.hardDefenseRejectedSanitizerReplacements =
            num(defenseSanitizeSummary and defenseSanitizeSummary.replacements, 0)
        ctx.stats.hardDefenseRejectedSanitizerReasonCounts =
            copyMap(defenseSanitizeSummary and defenseSanitizeSummary.reasonCounts or {})
        hardDefenseRecoveryReason = "hard_defense_no_sanitized_candidate"
    end

    local function withV2DefenseContext(fn)
        if hardDefenseRecoveryReason then
            return defenseScope.withRelaxedHardDefenseContext(ctx, contracts, hardDefenseRecoveryReason, fn)
        end
        return defenseScope.withSoftContext(ctx, contracts, fn)
    end

    local endPipelineResult = withV2DefenseContext(function(runtimeContracts)
        return require("ai_tournament.pipeline_v2_end").run(ai, state, ctx, runtimeContracts, {
            annotateCandidate = function(_, beforeState, callbackCtx, candidate)
                return annotateCandidateDiagnostics(callbackCtx.evaluator, beforeState, candidate, callbackCtx.aiPlayer)
            end,
            hardLockReason = M.hardLockReasonForSelection
        })
    end)
    if endPipelineResult and endPipelineResult.item then
        local item = endPipelineResult.item
        meta.reason = endPipelineResult.reason or "pipeline_v2_end_selected"
        meta.selected = item
        ctx.stats.coreExit = "pipeline_v2_end_selected"
        ctx.stats.fallbackSource = nil
        markSelectedDiagnostics(ai, ctx, state, item)
        ctx.stats.attackLossReason = computeAttackLossReason(ctx, item, nil, nil)
        local selectedContract = determineSelectedContract(ctx, contracts, item)
        ctx.stats.selectedContract = selectedContract
        meta.contract = selectedContract
        M._updatePipelineSelectedEvidence(
            ctx,
            contracts,
            item,
            selectedContract,
            ctx.stats.pipelineV2EndSelectedAcceptReason or meta.reason
        )
        meta.contractEvidence = contracts.evidence
        finalizeMeta(meta, ctx, state)
        return item.candidate.actions, meta
    elseif endPipelineResult then
        ctx.stats.pipelineV2EndFailedReason = endPipelineResult.reason or ctx.stats.pipelineV2EndFailedReason
        if endPipelineResult.attempted == true then
            meta.reason = endPipelineResult.reason or "pipeline_v2_end_failed_closed"
            meta.fallbackReason = "pipeline_v2_end_failed_closed"
            meta.contract = CONTRACTS.TECHNICAL_FALLBACK
            meta.contractEvidence = contracts.evidence
            ctx.stats.coreExit = ctx.stats.timeout and "pipeline_v2_end_timeout_no_selection" or "pipeline_v2_end_no_selection"
            ctx.stats.fallbackSource = "technical_fallback"
            ctx.stats.pipelineV2EndFailClosed = true
            ctx.stats.pipelineV2EndFellThroughToTournament = false
            finalizeMeta(meta, ctx, state)
            return nil, meta
        end
    end

    local midPipelineResult = withV2DefenseContext(function(runtimeContracts)
        return require("ai_tournament.pipeline_v2_mid").run(ai, state, ctx, runtimeContracts, {
            annotateCandidate = function(_, beforeState, callbackCtx, candidate)
                return annotateCandidateDiagnostics(callbackCtx.evaluator, beforeState, candidate, callbackCtx.aiPlayer)
            end,
            hardLockReason = M.hardLockReasonForSelection
        })
    end)
    if midPipelineResult and midPipelineResult.item then
        local item = midPipelineResult.item
        meta.reason = midPipelineResult.reason or "pipeline_v2_mid_selected"
        meta.selected = item
        ctx.stats.coreExit = "pipeline_v2_mid_selected"
        ctx.stats.fallbackSource = nil
        markSelectedDiagnostics(ai, ctx, state, item)
        ctx.stats.attackLossReason = computeAttackLossReason(ctx, item, nil, nil)
        local selectedContract = determineSelectedContract(ctx, contracts, item)
        ctx.stats.selectedContract = selectedContract
        meta.contract = selectedContract
        M._updatePipelineSelectedEvidence(
            ctx,
            contracts,
            item,
            selectedContract,
            ctx.stats.pipelineV2MidSelectedAcceptReason or meta.reason
        )
        meta.contractEvidence = contracts.evidence
        finalizeMeta(meta, ctx, state)
        return item.candidate.actions, meta
    elseif midPipelineResult then
        ctx.stats.pipelineV2MidFailedReason = midPipelineResult.reason or ctx.stats.pipelineV2MidFailedReason
        if midPipelineResult.attempted == true then
            meta.reason = midPipelineResult.reason or "pipeline_v2_mid_failed_closed"
            meta.fallbackReason = "pipeline_v2_mid_failed_closed"
            meta.contract = CONTRACTS.TECHNICAL_FALLBACK
            meta.contractEvidence = contracts.evidence
            ctx.stats.coreExit = ctx.stats.timeout and "pipeline_v2_mid_timeout_no_selection" or "pipeline_v2_mid_no_selection"
            ctx.stats.fallbackSource = "technical_fallback"
            ctx.stats.pipelineV2MidFailClosed = true
            ctx.stats.pipelineV2MidFellThroughToTournament = false
            finalizeMeta(meta, ctx, state)
            return nil, meta
        end
    end

    if ctx.cfg.PIPELINE_V2_ENABLED ~= false then
        local pipelineResult = withV2DefenseContext(function(runtimeContracts)
            return pipelineV2.run(ai, state, ctx, runtimeContracts, {
                annotateCandidate = function(_, beforeState, callbackCtx, candidate)
                    return annotateCandidateDiagnostics(callbackCtx.evaluator, beforeState, candidate, callbackCtx.aiPlayer)
                end,
                addressesActiveDefense = itemAddressesActiveDefense,
                earlyGateRejects = function(callbackAI, beforeState, callbackCtx, callbackContracts, item)
                    if callbackCtx and callbackCtx.stats then
                        callbackCtx.stats.pipelineV2EarlyGatePath = "v2"
                    end
                    return require("ai_tournament.pipeline_v2_early_gate").rejects(
                        callbackAI,
                        beforeState,
                        callbackCtx,
                        callbackContracts,
                        item
                    )
                end,
                hardLockReason = M.hardLockReasonForSelection
            })
        end)

        if pipelineResult and pipelineResult.item then
            local item = pipelineResult.item
            meta.reason = pipelineResult.reason or "pipeline_v2_selected"
            meta.selected = item
            if pipelineResult.fallbackSource then
                meta.fallbackReason = pipelineResult.recoveredFrom or pipelineResult.reason
                ctx.stats.pipelineV2FailedReason = pipelineResult.recoveredFrom
                ctx.stats.coreExit = pipelineResult.reason or "pipeline_v2_best_fast_before_fail_closed"
                ctx.stats.fallbackSource = pipelineResult.fallbackSource
            else
                ctx.stats.coreExit = "pipeline_v2_selected"
                ctx.stats.fallbackSource = nil
            end
            markSelectedDiagnostics(ai, ctx, state, item)
            ctx.stats.attackLossReason = computeAttackLossReason(ctx, item, nil, nil)
            local selectedContract = determineSelectedContract(ctx, contracts, item)
            ctx.stats.selectedContract = selectedContract
            meta.contract = selectedContract
            M._updatePipelineSelectedEvidence(
                ctx,
                contracts,
                item,
                selectedContract,
                ctx.stats.pipelineV2SelectedAcceptReason or meta.reason
            )
            meta.contractEvidence = contracts.evidence
            finalizeMeta(meta, ctx, state)
            return item.candidate.actions, meta
        end

        ctx.stats.pipelineV2FailedReason = pipelineResult and pipelineResult.reason or "pipeline_v2_no_result"
        if pipelineResult and pipelineResult.attempted == false then
            ctx.stats.pipelineV2Skipped = true
        end
        ctx.stats.pipelineV2FailClosed = true
        meta.reason = ctx.stats.pipelineV2FailedReason
        meta.fallbackReason = "pipeline_v2_failed_closed"
        meta.contract = CONTRACTS.TECHNICAL_FALLBACK
        meta.contractEvidence = contracts.evidence
        ctx.stats.coreExit = ctx.stats.timeout and "pipeline_v2_timeout_no_selection" or "pipeline_v2_no_selection"
        ctx.stats.fallbackSource = "technical_fallback"
        finalizeMeta(meta, ctx, state)
        return nil, meta
    else
        ctx.stats.pipelineV2FailedReason = "pipeline_v2_disabled"
        ctx.stats.pipelineV2FailClosed = true
        meta.reason = "pipeline_v2_disabled"
        meta.fallbackReason = "pipeline_v2_disabled"
        meta.contract = CONTRACTS.TECHNICAL_FALLBACK
        meta.contractEvidence = contracts.evidence
        ctx.stats.coreExit = "pipeline_v2_disabled"
        ctx.stats.fallbackSource = "technical_fallback"
        finalizeMeta(meta, ctx, state)
        return nil, meta
    end

    meta.reason = "pipeline_v2_exhausted"
    meta.fallbackReason = "pipeline_v2_exhausted"
    meta.contract = CONTRACTS.TECHNICAL_FALLBACK
    meta.contractEvidence = contracts.evidence
    ctx.stats.coreExit = "pipeline_v2_exhausted"
    ctx.stats.fallbackSource = "technical_fallback"
    ctx.stats.pipelineV2FailClosed = true
    finalizeMeta(meta, ctx, state)
    return nil, meta
end

function M.logDecision(ai, meta, sequence, sanitizeSummary)
    debugModule.logDecision(ai, meta, sequence, sanitizeSummary)
end

return M
