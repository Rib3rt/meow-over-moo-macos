package.path = package.path .. ";./?.lua"

local results = {}

local function runTest(name, fn)
    local startedAt = os.clock()
    local ok, err = xpcall(fn, debug.traceback)
    results[#results + 1] = {
        name = name,
        ok = ok,
        err = err,
        ms = (os.clock() - startedAt) * 1000
    }
end

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error((message or "assertEquals failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function unit(name, player, row, col, overrides)
    local hp = ({
        Commandant = 12,
        Wingstalker = 3,
        Crusher = 4,
        Bastion = 6,
        Cloudstriker = 4,
        Earthstalker = 3,
        Healer = 4,
        Artillery = 5
    })[name] or 3
    local out = {
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = hp,
        startingHp = hp,
        move = 2,
        atkRange = 1,
        atkDamage = 2,
        hasActed = false,
        hasMoved = false,
        actionsUsed = 0
    }
    for key, value in pairs(overrides or {}) do
        out[key] = value
    end
    return out
end

local function clone(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[key] = clone(child)
    end
    return out
end

local function stateWith(enemyDamage)
    return {
        currentPlayer = 1,
        currentTurn = 11,
        turnNumber = 11,
        gridSize = 8,
        units = {
            unit("Crusher", 1, 2, 2, {currentHp = 4, startingHp = 4}),
            unit("Wingstalker", 1, 1, 1),
            unit("Earthstalker", 2, 4, 6, {atkRange = 3, atkDamage = enemyDamage or 2, move = 0})
        },
        neutralBuildings = {},
        commandHubs = {
            [1] = {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 12, startingHp = 12},
            [2] = {name = "Commandant", player = 2, row = 8, col = 7, currentHp = 12, startingHp = 12}
        },
        supply = {
            [1] = {},
            [2] = {}
        }
    }
end

local function getUnitAt(state, row, col)
    for _, item in ipairs(state.units or {}) do
        if item and item.row == row and item.col == col then
            return item
        end
    end
    return nil
end

local function mkAI()
    return {
        getOpponentPlayer = function(_, playerId)
            return playerId == 1 and 2 or 1
        end,
        isHubUnit = function(_, item)
            return item and item.name == "Commandant"
        end,
        isObstacleUnit = function(_, item)
            return item and item.name == "Rock"
        end,
        getUnitAtPosition = function(_, state, row, col)
            return getUnitAt(state, row, col)
        end,
        calculateDamage = function(_, attacker)
            return attacker and attacker.atkDamage or 0
        end,
        getUnitBaseValue = function(_, item)
            return ({
                Crusher = 80,
                Earthstalker = 75,
                Wingstalker = 45,
                Commandant = 150
            })[item and item.name] or 25
        end
    }
end

local function applyAction(nextState, action)
    if action.type == "move" and action.unit and action.target then
        local moved = getUnitAt(nextState, action.unit.row, action.unit.col)
        if moved then
            moved.row = action.target.row
            moved.col = action.target.col
            moved.hasMoved = true
            moved.actionsUsed = (moved.actionsUsed or 0) + 1
        end
    elseif action.type == "attack" and action.unit and action.target then
        local attacker = getUnitAt(nextState, action.unit.row, action.unit.col)
        local target = getUnitAt(nextState, action.target.row, action.target.col)
        if attacker and target then
            target.currentHp = math.max(0, (target.currentHp or target.startingHp or 0) - (attacker.atkDamage or 0))
            attacker.hasActed = true
            attacker.actionsUsed = (attacker.actionsUsed or 0) + 1
        end
    elseif action.type == "supply_deploy" and action.target then
        local deployed = unit(action.unitName or action.unitType or "Crusher", nextState.currentPlayer or 1, action.target.row, action.target.col)
        deployed.hasMoved = true
        deployed.actionsUsed = 1
        nextState.units[#nextState.units + 1] = deployed
    end
end

local function simulate(_, state, actions)
    local nextState = clone(state)
    for _, action in ipairs(actions or {}) do
        applyAction(nextState, action)
    end
    return nextState
end

local function signature(action)
    if action.type == "move" or action.type == "attack" or action.type == "repair" then
        return string.format("%s:%d,%d>%d,%d", action.type, action.unit.row, action.unit.col, action.target.row, action.target.col)
    end
    if action.type == "supply_deploy" then
        return string.format("deploy:%s>%d,%d", action.unitName or action.unitType or "?", action.target.row, action.target.col)
    end
    return tostring(action.type)
end

local function sequenceSignature(actions)
    local parts = {}
    for _, action in ipairs(actions or {}) do
        parts[#parts + 1] = signature(action)
    end
    return table.concat(parts, "|")
end

local function midMap(enemyDamage)
    local damage = enemyDamage or 2
    local byKey = {
        ["2,2"] = {key = "2,2", row = 2, col = 2, value = 80, status = "owned_pressure", free = false},
        ["4,4"] = {
            key = "4,4",
            row = 4,
            col = 4,
            value = 620,
            status = "pressure_cell",
            free = true,
            reachable = true,
            enemyPunish = {damage = damage, lethal = damage >= 4},
            coveredIfOccupied = false,
            enemyHubDistance = 7,
            progress = 3,
            compactReasons = {"mid_forward_progress", "mid_board_centrality"}
        },
        ["1,2"] = {
            key = "1,2",
            row = 1,
            col = 2,
            value = 180,
            status = "pressure_cell",
            free = true,
            reachable = true,
            compactReasons = {"mid_support"}
        }
    }
    return {
        byKey = byKey,
        cells = {byKey["4,4"], byKey["1,2"], byKey["2,2"]},
        positionTop = {byKey["4,4"], byKey["1,2"]}
    }
end

local function midPersonality()
    local profile = require("ai_tournament.mid_personality").resolve(nil, nil, {aiReference = "burt"}, "burt")
    return {
        profile = profile,
        byKey = {
            ["2,2"] = {key = "2,2", row = 2, col = 2, value = 110, status = "owned_pressure"},
            ["4,4"] = {
                key = "4,4",
                row = 4,
                col = 4,
                value = 760,
                status = "pressure_cell",
                acceptedForMid = true,
                intent = "pressure",
                riskBand = "contested_ok"
            },
            ["1,2"] = {
                key = "1,2",
                row = 1,
                col = 2,
                value = 210,
                status = "pressure_cell",
                acceptedForMid = true,
                intent = "cover",
                riskBand = "stable"
            }
        }
    }
end

local function ctxWith(firstMoves, secondMoves, attackActions)
    return {
        aiPlayer = 1,
        enemyPlayer = 2,
        aiReference = "burt",
        phase = {name = "mid", mid = true, early = false},
        cfg = {
            PIPELINE_V2_MID_ENABLED = true,
            PIPELINE_V2_MID_ATTACK_CANDIDATES_ENABLED = true,
            PIPELINE_V2_MID_POSITION_CANDIDATES_ENABLED = true,
            PIPELINE_V2_MID_POSITION_SCAN_CAP = 4,
            PIPELINE_V2_MID_POSITION_CANDIDATE_CAP = 4,
            PIPELINE_V2_MID_POSITION_SECOND_SCAN_CAP = 4,
            PIPELINE_V2_MID_POSITION_SECOND_COMPLETION_CAP = 2,
            PIPELINE_V2_MID_POSITION_SECOND_EXTRA_MS = 500,
            PIPELINE_V2_MID_POSITION_MIN_GAIN = 10,
            PIPELINE_V2_MID_MAX_RANKED = 4,
            PIPELINE_V2_MID_MAX_FINALISTS = 2,
            PIPELINE_V2_CLOUDSTRIKER_MELEE_CONTACT_PENALTY_ENABLED = true,
            PIPELINE_V2_CLOUDSTRIKER_MELEE_CONTACT_PENALTY = 3200
        },
        stats = {},
        beginStage = function() end,
        endStage = function() end,
        cache = {
            simulate = simulate
        },
        turnEnumerator = {
            actionSignature = signature,
            sequenceSignature = sequenceSignature,
            collectTournamentActions = function(_, _, _, _, opts)
                local source = {}
                if opts and opts.includeMove == true and opts.includeAttack == false
                    and opts.includeRepair == false and opts.includeDeploy == false then
                    source = firstMoves or {}
                elseif opts and opts.includeMove == false and opts.includeAttack == true
                    and opts.includeRepair == false and opts.includeDeploy == false then
                    source = attackActions or {}
                elseif opts and opts.includeMove == true and opts.includeAttack == true
                    and opts.includeRepair == true and opts.includeDeploy == true then
                    source = secondMoves or {}
                elseif opts and opts.includeMove == true and opts.includeAttack == false
                    and opts.includeRepair == true and opts.includeDeploy == true then
                    source = secondMoves or {}
                end
                local out = {}
                for _, action in ipairs(source) do
                    out[#out + 1] = {
                        action = action,
                        signature = signature(action),
                        cheapScore = 0
                    }
                end
                return out
            end
        },
        score = require("ai_tournament.score"),
        evaluator = {
            isCommandantDead = function()
                return false
            end
        }
    }
end

runTest("mid_position_accepts_nonlethal_pressure_move", function()
    local generator = require("ai_tournament.mid_position_candidates")
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
    }
    local context = ctxWith(firstMoves, secondMoves)
    context.midPersonality = midPersonality()
    local candidates = generator.generate(mkAI(), stateWith(2), context, midMap(2), {})

    assertEquals(#candidates, 1, "nonlethal pressure move should produce a candidate")
    assertEquals(candidates[1].source, "mid_v2_position", "candidate should be position V2")
    assertEquals(#candidates[1].actions, 2, "position candidate must be a full turn")
    assertTrue(candidates[1].completeTurn == true, "position candidate should be marked complete")
    assertTrue(candidates[1].midPosition and candidates[1].midPosition.accepted == true, "position payload should be accepted")
    assertEquals(candidates[1].midPosition.exposureDamage, 2, "nonlethal damage should be tracked")
end)

runTest("mid_position_second_uses_own_additive_budget", function()
    local generator = require("ai_tournament.mid_position_candidates")
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
    }
    local context = ctxWith(firstMoves, secondMoves)
    context.midPersonality = midPersonality()
    context.hardBudgetMs = 1000
    context.elapsedMs = function()
        return 1000
    end
    context.remainingMs = function()
        return math.max(0, (context.hardBudgetMs or 0) - context.elapsedMs())
    end
    context._insidePositionSecond = false
    context.shouldStop = function()
        return context._insidePositionSecond == true
            and context.remainingMs()
            and context.remainingMs() <= 0
    end
    local originalCollect = context.turnEnumerator.collectTournamentActions
    context.turnEnumerator.collectTournamentActions = function(...)
        local args = {...}
        local opts = args[5]
        if opts and opts.includeMove == true and opts.includeRepair == true and opts.includeDeploy == true then
            context._insidePositionSecond = true
        end
        return originalCollect(...)
    end

    local candidates = generator.generate(mkAI(), stateWith(2), context, midMap(2), {})

    assertEquals(#candidates, 1, "position second completion should get its own local time window")
    assertEquals(context.stats.pipelineV2MidPositionSecondExtraMs, 500)
    assertTrue(
        (context.stats.pipelineV2MidPositionSecondCompleted or 0) >= 1,
        "position second completion should be logged"
    )
end)

runTest("mid_position_second_prioritizes_cover_for_exposed_prefix", function()
    local generator = require("ai_tournament.mid_position_candidates")
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local badBackfill = {
        type = "move",
        unit = {row = 4, col = 1},
        target = {row = 2, col = 1}
    }
    local coverPrefix = {
        type = "move",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 2}
    }
    local context = ctxWith(firstMoves, {badBackfill, coverPrefix})
    context.cfg.PIPELINE_V2_MID_POSITION_SECOND_SCAN_CAP = 1
    context.cfg.PIPELINE_V2_MID_POSITION_SECOND_COMPLETION_CAP = 1
    context.midPersonality = midPersonality()
    context.midPersonality.byKey["2,1"] = {
        key = "2,1",
        row = 2,
        col = 1,
        value = 820,
        status = "pressure_cell",
        acceptedForMid = true,
        intent = "pressure",
        riskBand = "stable"
    }
    context.midPersonality.byKey["4,2"] = {
        key = "4,2",
        row = 4,
        col = 2,
        value = 180,
        status = "pressure_cell",
        acceptedForMid = true,
        intent = "cover",
        riskBand = "stable"
    }
    local map = midMap(2)
    map.byKey["2,1"] = {
        key = "2,1",
        row = 2,
        col = 1,
        value = 760,
        status = "pressure_cell",
        free = true,
        reachable = true
    }
    map.byKey["4,2"] = {
        key = "4,2",
        row = 4,
        col = 2,
        value = 160,
        status = "pressure_cell",
        free = true,
        reachable = true
    }
    local state = stateWith(2)
    state.units[#state.units + 1] = unit("Cloudstriker", 1, 4, 1, {atkRange = 3, move = 3})

    local candidates = generator.generate(mkAI(), state, context, map, {})

    assertEquals(#candidates, 1, "covering second action should be found even behind a low scan cap")
    assertEquals(candidates[1].actions[2].target.row, 4)
    assertEquals(candidates[1].actions[2].target.col, 2)
    assertTrue(candidates[1].midPosition.secondCoversPrefix == true, "second action should mark prefix coverage")
    assertEquals(context.stats.pipelineV2MidPositionSecondReasonCounts.mid_second_cover_prefix, 1)
end)

runTest("mid_position_second_smart_order_flag_restores_raw_scan_order", function()
    local generator = require("ai_tournament.mid_position_candidates")
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local badBackfill = {
        type = "move",
        unit = {row = 4, col = 1},
        target = {row = 2, col = 1}
    }
    local coverPrefix = {
        type = "move",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 2}
    }
    local context = ctxWith(firstMoves, {badBackfill, coverPrefix})
    context.cfg.PIPELINE_V2_MID_POSITION_SECOND_SCAN_CAP = 1
    context.cfg.PIPELINE_V2_MID_POSITION_SECOND_COMPLETION_CAP = 1
    context.cfg.PIPELINE_V2_MID_POSITION_SECOND_SMART_ORDER_ENABLED = false
    context.midPersonality = midPersonality()
    context.midPersonality.byKey["2,1"] = {
        key = "2,1",
        row = 2,
        col = 1,
        value = 820,
        status = "pressure_cell",
        acceptedForMid = true,
        intent = "pressure",
        riskBand = "stable"
    }
    context.midPersonality.byKey["4,2"] = {
        key = "4,2",
        row = 4,
        col = 2,
        value = 180,
        status = "pressure_cell",
        acceptedForMid = true,
        intent = "cover",
        riskBand = "stable"
    }
    local map = midMap(2)
    map.byKey["2,1"] = {
        key = "2,1",
        row = 2,
        col = 1,
        value = 760,
        status = "pressure_cell",
        free = true,
        reachable = true
    }
    map.byKey["4,2"] = {
        key = "4,2",
        row = 4,
        col = 2,
        value = 160,
        status = "pressure_cell",
        free = true,
        reachable = true
    }
    local state = stateWith(2)
    state.units[#state.units + 1] = unit("Cloudstriker", 1, 4, 1, {atkRange = 3, move = 3})

    local candidates = generator.generate(mkAI(), state, context, map, {})

    assertEquals(#candidates, 1, "flag off should keep the raw first legal second action")
    assertEquals(candidates[1].actions[2].target.row, 2)
    assertEquals(candidates[1].actions[2].target.col, 1)
    assertTrue(candidates[1].midPosition.secondCoversPrefix == false, "flag off should not add cover-prefix scoring")
end)

runTest("mid_position_penalizes_lethal_pressure_move_without_veto", function()
    local generator = require("ai_tournament.mid_position_candidates")
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
    }
    local context = ctxWith(firstMoves, secondMoves)
    context.midPersonality = midPersonality()
    local candidates = generator.generate(mkAI(), stateWith(4), context, midMap(4), {})

    assertEquals(#candidates, 1, "lethal pressure move should still produce a candidate")
    assertTrue(candidates[1].midPosition.lethalExposure == true, "lethal exposure should be marked")
    assertTrue((candidates[1].midPosition.destinationExposurePenalty or 0) > 0, "lethal exposure should be scored down")
end)

runTest("cloudstriker_melee_contact_penalty_allows_defense_exception", function()
    local movePatternPenalty = require("ai_tournament.move_pattern_penalty")
    local action = {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    local state = stateWith(0)
    state.units = {
        unit("Cloudstriker", 1, 2, 2, {atkRange = 3, move = 3}),
        unit("Earthstalker", 2, 4, 5, {atkRange = 1, atkDamage = 2, move = 0})
    }
    local context = ctxWith({action}, {})

    local penalty = movePatternPenalty.penalty(mkAI(), state, context, action)
    assertTrue(penalty >= 3200, "Cloudstriker melee contact should be strongly penalized")

    local adjusted, applied = movePatternPenalty.adjustScore(mkAI(), state, context, action, 1000, context.stats)
    assertEquals(applied, penalty, "adjustScore should apply the same penalty")
    assertTrue(adjusted < 0, "penalty should dominate casual pressure value")
    assertEquals(context.stats.cloudstrikerMeleeContactPenalized, 1)

    context.activeContracts = {defenseActive = true}
    assertEquals(
        movePatternPenalty.penalty(mkAI(), state, context, action),
        0,
        "defensive emergency may still use Cloudstriker as a block"
    )
end)

runTest("mid_position_penalizes_cloudstriker_melee_contact_without_veto", function()
    local generator = require("ai_tournament.mid_position_candidates")
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
    }
    local context = ctxWith(firstMoves, secondMoves)
    context.midPersonality = midPersonality()
    local state = stateWith(0)
    state.units = {
        unit("Cloudstriker", 1, 2, 2, {atkRange = 3, move = 3}),
        unit("Wingstalker", 1, 1, 1),
        unit("Earthstalker", 2, 4, 5, {atkRange = 1, atkDamage = 2, move = 0})
    }

    local candidates = generator.generate(mkAI(), state, context, midMap(0), {})

    assertEquals(#candidates, 1, "Cloudstriker melee-contact pressure should remain a candidate")
    assertTrue(candidates[1].cheapScore < -1000, "melee-contact pressure should be ranked far down")
    assertEquals(context.stats.cloudstrikerMeleeContactPenalized, 1)
    assertTrue(
        (context.stats.cloudstrikerMeleeContactPenaltyMax or 0) >= 3200,
        "Cloudstriker melee-contact penalty should be tracked"
    )
end)

runTest("mid_position_static_exposure_does_not_reanalyze_punish_map", function()
    local generator = require("ai_tournament.mid_position_candidates")
    local punishMap = require("ai_tournament.punish_map")
    local originalAnalyze = punishMap.analyzeCell
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
    }
    local context = ctxWith(firstMoves, secondMoves)
    context.midPersonality = midPersonality()
    context.cfg.PIPELINE_V2_MID_POSITION_DYNAMIC_EXPOSURE_ENABLED = false

    local calls = 0
    local ok, err = pcall(function()
        punishMap.analyzeCell = function()
            calls = calls + 1
            error("dynamic punish analysis should not run in static mid-position mode", 2)
        end
        local candidates = generator.generate(mkAI(), stateWith(2), context, midMap(2), {})
        assertEquals(#candidates, 1, "static map exposure should still produce a candidate")
    end)

    punishMap.analyzeCell = originalAnalyze
    if not ok then
        error(err, 0)
    end
    assertEquals(calls, 0, "static mid-position should reuse map exposure data")
end)

runTest("mid_position_requires_context_cache_simulation", function()
    local generator = require("ai_tournament.mid_position_candidates")
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
    }
    local context = ctxWith(firstMoves, secondMoves)
    context.cache = nil
    context.midPersonality = midPersonality()
    local ai = mkAI()
    ai.simulateActionSequenceForPlayer = function()
        error("mid position should not bypass ctx.cache.simulate", 2)
    end

    local candidates = generator.generate(ai, stateWith(2), context, midMap(2), {})

    assertEquals(#candidates, 0, "position candidates should reject without context simulation")
    assertEquals(
        context.stats.pipelineV2MidPositionRejectedReasons.mid_position_simulation_failed,
        1,
        "missing cache should be logged as simulation failed"
    )
end)

runTest("pipeline_mid_selects_position_candidate_without_attack", function()
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonalityModule = require("ai_tournament.mid_personality")
    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonalityModule.interpretMap
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
    }
    local context = ctxWith(firstMoves, secondMoves)
    local map = midMap(2)
    local personality = midPersonality()

    local ok, err = pcall(function()
        midPositionMap.build = function()
            return map
        end
        midPersonalityModule.interpretMap = function()
            return personality
        end

        local result = require("ai_tournament.pipeline_v2_mid").run(mkAI(), stateWith(2), context, {}, {})
        assertTrue(result and result.item, "pipeline should select position pressure")
        assertEquals(result.reason, "pipeline_v2_mid_selected", "pipeline should report mid selection")
        assertEquals(result.item.candidate.source, "mid_v2_position", "selected candidate should be position V2")
        assertEquals(#result.item.candidate.actions, 2, "pipeline position selection should be a full turn")
        assertEquals(context.stats.pipelineV2MidPositionCandidates, 1, "position candidate count should be logged")
    end)

    midPositionMap.build = originalBuild
    midPersonalityModule.interpretMap = originalInterpret
    if not ok then
        error(err, 0)
    end
end)

runTest("pipeline_mid_uses_deploy_candidate_when_no_attack_or_move_exists", function()
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonalityModule = require("ai_tournament.mid_personality")
    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonalityModule.interpretMap
    local deploy = {type = "supply_deploy", unitName = "Artillery", target = {row = 7, col = 8}}
    local context = ctxWith({}, {}, {})
    context.supply = {own = {count = 1}, enemy = {count = 0}}
    context.supplyPlanner = {
        getDeployActionEntries = function()
            return {
                {
                    action = deploy,
                    signature = signature(deploy),
                    cheapScore = 0
                }
            }
        end
    }
    local map = midMap(0)
    local personality = midPersonality()
    local state = stateWith(0)
    state.units = {
        unit("Crusher", 1, 2, 2, {actionsUsed = 2, hasMoved = true, hasActed = true}),
        unit("Earthstalker", 2, 6, 6, {currentHp = 3, startingHp = 3})
    }

    local ok, err = pcall(function()
        midPositionMap.build = function()
            return map
        end
        midPersonalityModule.interpretMap = function()
            return personality
        end

        local result = require("ai_tournament.pipeline_v2_mid").run(mkAI(), state, context, {}, {})
        assertTrue(result and result.item, "pipeline should return a deploy candidate instead of failing closed")
        assertEquals(result.reason, "pipeline_v2_mid_selected")
        assertEquals(result.item.candidate.source, "mid_v2_deploy")
        assertTrue(result.item.candidate.containsDeploy == true, "deploy candidate should be explicit")
        assertEquals(#result.item.candidate.actions, 2, "deploy candidate should still complete the turn")
        assertEquals(result.item.candidate.actions[2].type, "skip", "deploy candidate should synthesize a tracked skip if no second action exists")
        assertEquals(context.stats.pipelineV2MidDeploySkipCompletion, 1, "deploy skip completion should be observable")
        assertEquals(context.stats.pipelineV2MidDeployCandidates, 1)
    end)

    midPositionMap.build = originalBuild
    midPersonalityModule.interpretMap = originalInterpret
    if not ok then
        error(err, 0)
    end
end)

runTest("endgame_position_deploy_uses_light_penalty_when_own_supply_exists", function()
    local scorer = require("ai_tournament.mid_score")
    local context = ctxWith({}, {}, {})
    context.pipelineV2EndRuntime = true
    context.phase = {name = "endgame", endgame = true, mid = false, early = false, supply = {[1] = 1, [2] = 0}}
    context.supply = {own = {count = 1}, enemy = {count = 0}}
    context.cfg.PIPELINE_V2_ENDGAME_POSITION_ONLY_PENALTY = 1600
    context.cfg.PIPELINE_V2_ENDGAME_DEPLOY_PENALTY = 9000
    context.cfg.PIPELINE_V2_ENDGAME_DEPLOY_WITH_SUPPLY_PENALTY = 300
    local candidate = {
        signature = "end_deploy_position",
        source = "mid_v2_deploy",
        containsDeploy = true,
        containsAttack = false,
        tacticalTags = {midV2 = true, midDeploy = true},
        midPosition = {
            accepted = true,
            reason = "mid_deploy_staging",
            score = 0,
            targetValue = 100,
            pressureGain = 100,
            exposureDamage = 0
        }
    }

    local score = scorer.score(mkAI(), stateWith(0), context, candidate, {})

    assertTrue(score.breakdown and score.breakdown.endgame, "endgame deploy scoring should be visible")
    assertEquals(score.breakdown.endgame.deployPenalty, 300, "own remaining supply should keep deploy available in endgame")
    assertEquals(score.breakdown.endgame.ownSupply, 1, "own supply should be tracked in the score")
end)

runTest("endgame_late_aggression_starts_after_turn_50_for_unit_advantage_or_equal", function()
    local scorer = require("ai_tournament.mid_score")
    local context = ctxWith({}, {}, {})
    context.pipelineV2EndRuntime = true
    context.phase = {name = "endgame", endgame = true, mid = false, early = false, supply = {[1] = 0, [2] = 0}}
    context.cfg.PIPELINE_V2_ENDGAME_LATE_AGGRESSION_ENABLED = true
    context.cfg.PIPELINE_V2_ENDGAME_LATE_AGGRESSION_START_TURN = 51
    context.cfg.PIPELINE_V2_ENDGAME_LATE_AGGRESSION_BASE_BONUS = 1000
    context.cfg.PIPELINE_V2_ENDGAME_LATE_AGGRESSION_PER_TURN = 0
    context.cfg.PIPELINE_V2_ENDGAME_LATE_AGGRESSION_UNIT_ADVANTAGE_BONUS = 500
    context.cfg.PIPELINE_V2_ENDGAME_LATE_AGGRESSION_DAMAGE_WEIGHT = 0
    context.cfg.PIPELINE_V2_ENDGAME_LATE_AGGRESSION_KILL_BONUS = 0
    context.cfg.PIPELINE_V2_ENDGAME_LATE_AGGRESSION_COMMANDANT_WEIGHT = 0

    local candidate = {
        signature = "late_attack",
        containsAttack = true,
        actions = {{type = "attack"}},
        tacticalTags = {midV2 = true},
        midTrade = {
            accepted = true,
            reason = "mid_trade_damage",
            totalDamage = 1,
            kills = 0,
            commandantDamage = 0,
            materialDelta = 0,
            hpTradeNet = 1,
            expectedLoss = 0,
            score = 0
        }
    }

    local advantaged = stateWith(1)
    advantaged.currentTurn = 51
    advantaged.turnNumber = 51
    local equal = stateWith(1)
    equal.currentTurn = 51
    equal.turnNumber = 51
    equal.units = {
        unit("Crusher", 1, 2, 2, {currentHp = 4, startingHp = 4}),
        unit("Earthstalker", 2, 4, 6, {atkRange = 3, atkDamage = 1, move = 0})
    }
    local behind = stateWith(1)
    behind.currentTurn = 51
    behind.turnNumber = 51
    behind.units = {
        unit("Crusher", 1, 2, 2, {currentHp = 4, startingHp = 4}),
        unit("Earthstalker", 2, 4, 6, {atkRange = 3, atkDamage = 1, move = 0}),
        unit("Wingstalker", 2, 6, 6)
    }

    local advantagedScore = scorer.score(mkAI(), advantaged, context, clone(candidate), {})
    local equalScore = scorer.score(mkAI(), equal, context, clone(candidate), {})
    local behindScore = scorer.score(mkAI(), behind, context, clone(candidate), {})
    local lateMidContext = clone(context)
    lateMidContext.pipelineV2EndRuntime = false
    lateMidContext.phase = {name = "mid", endgame = false, mid = true, early = false}
    local lateMidScore = scorer.score(mkAI(), advantaged, lateMidContext, clone(candidate), {})

    assertTrue(advantagedScore.breakdown.endgameLateAggression ~= nil, "unit advantage should activate late aggression")
    assertEquals(advantagedScore.breakdown.endgameLateAggression.ownUnits, 2)
    assertEquals(advantagedScore.breakdown.endgameLateAggression.enemyUnits, 1)
    assertEquals(advantagedScore.breakdown.endgameLateAggression.unitAdvantage, 1)
    assertTrue(equalScore.breakdown.endgameLateAggression ~= nil, "equal units should activate late aggression for both sides")
    assertEquals(equalScore.breakdown.endgameLateAggression.equalUnits, true)
    assertTrue(behindScore.breakdown.endgameLateAggression == nil, "unit disadvantage should not receive the extra aggression boost")
    assertTrue(advantagedScore.force > behindScore.force, "late aggression should be a score boost, not a veto")
    assertTrue(lateMidScore.breakdown.endgameLateAggression ~= nil, "turn 51 aggression should not depend on supply endgame")
end)

runTest("draw_pressure_urgency_starts_at_minus_four_and_peaks_before_draw", function()
    local drawPressure = require("ai_tournament.draw_pressure")
    local ai = mkAI()
    local state = stateWith(0)
    state.currentTurn = 11
    state.turnNumber = 11

    state.turnsWithoutDamage = 0
    local zero = drawPressure.build(ai, state, {})
    assertEquals(zero.noInteractionLimit, 5)
    assertEquals(zero.pressureStreak, 1)
    assertEquals(zero.nearStreak, 3)
    assertEquals(zero.criticalStreak, 4)
    assertEquals(zero.urgency, 0)
    assertTrue(zero.pressureLimit ~= true, "no pressure before the -4 window")

    state.turnsWithoutDamage = 1
    local minusFour = drawPressure.build(ai, state, {})
    assertEquals(minusFour.remainingBeforeLimit, 4)
    assertEquals(minusFour.urgency, 1)
    assertTrue(minusFour.pressureLimit == true, "pressure should start at draw -4")
    assertTrue(minusFour.nearLimit ~= true, "near pressure should still wait until -2")

    state.turnsWithoutDamage = 3
    local minusTwo = drawPressure.build(ai, state, {})
    assertEquals(minusTwo.remainingBeforeLimit, 2)
    assertEquals(minusTwo.urgency, 3)
    assertTrue(minusTwo.nearLimit == true, "near pressure should remain the -2 band")

    state.turnsWithoutDamage = 4
    local lastUseful = drawPressure.build(ai, state, {})
    assertEquals(lastUseful.remainingBeforeLimit, 1)
    assertEquals(lastUseful.urgency, lastUseful.urgencyMax)
    assertTrue(lastUseful.criticalLimit == true, "last useful turn before draw should be critical")
end)

runTest("pipeline_mid_draw_minus_four_starts_preferring_interaction", function()
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonalityModule = require("ai_tournament.mid_personality")
    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonalityModule.interpretMap
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
    }
    local attacks = {
        {type = "attack", unit = {row = 4, col = 1}, target = {row = 4, col = 6}}
    }
    local context = ctxWith(firstMoves, secondMoves, attacks)
    local map = midMap(0)
    local personality = midPersonality()
    map.byKey["4,4"].value = 12000
    personality.byKey["4,4"].value = 12000
    local state = stateWith(0)
    state.turnsWithoutDamage = 1
    state.units[#state.units + 1] = unit("Artillery", 1, 4, 1, {atkRange = 5, atkDamage = 1, move = 0})

    local ok, err = pcall(function()
        midPositionMap.build = function()
            return map
        end
        midPersonalityModule.interpretMap = function()
            return personality
        end

        local result = require("ai_tournament.pipeline_v2_mid").run(mkAI(), state, context, {}, {})
        assertTrue(result and result.item, "pipeline should return a mid candidate")
        assertEquals(result.item.candidate.source, "mid_v2_attack", "draw -4 should already prefer accepted interaction")
        assertTrue(result.item.candidate.containsAttack == true, "selected candidate should interact")
        assertEquals(context.stats.pipelineV2MidDrawPressureWindow, true)
        assertEquals(context.stats.pipelineV2MidDrawPressureNearLimit, false)
        assertEquals(context.stats.pipelineV2MidDrawPressureStreak, 1)
        assertEquals(context.stats.pipelineV2MidDrawPressureUrgency, 1)
    end)

    midPositionMap.build = originalBuild
    midPersonalityModule.interpretMap = originalInterpret
    if not ok then
        error(err, 0)
    end
end)

runTest("mid_draw_wave_prefers_second_approach_over_deploy_stall", function()
    local generator = require("ai_tournament.mid_position_candidates")
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "supply_deploy", unitName = "Artillery", target = {row = 1, col = 2}},
        {type = "move", unit = {row = 1, col = 1}, target = {row = 3, col = 3}}
    }
    local context = ctxWith(firstMoves, secondMoves)
    context.stats.legalAttackActions = 0
    context.stats.legalMoveAttackActions = 0
    context.midPersonality = midPersonality()
    context.midPersonality.byKey["3,3"] = {
        key = "3,3",
        row = 3,
        col = 3,
        value = 120,
        status = "pressure_cell",
        acceptedForMid = true,
        intent = "pressure",
        riskBand = "stable"
    }
    local map = midMap(0)
    map.byKey["3,3"] = {
        key = "3,3",
        row = 3,
        col = 3,
        value = 120,
        status = "pressure_cell",
        free = true,
        reachable = true,
        enemyPunish = {damage = 0, lethal = false},
        coveredIfOccupied = true
    }
    local state = stateWith(0)
    state.turnsWithoutDamage = 1
    state.units = {
        unit("Crusher", 1, 2, 2, {currentHp = 4, startingHp = 4}),
        unit("Wingstalker", 1, 1, 1),
        unit("Earthstalker", 2, 6, 6, {currentHp = 3, startingHp = 3})
    }

    local candidates = generator.generate(mkAI(), state, context, map, {})

    assertTrue(#candidates > 0, "draw pressure should still produce position candidates")
    assertEquals(candidates[1].actions[2].type, "move", "draw wave should prefer a second approach over a deploy stall")
    assertTrue(
        (candidates[1].midPosition.secondDrawPressureScore or 0) > 0,
        "second action draw pressure bonus should be visible"
    )
end)

runTest("pipeline_mid_draw_minus_two_prefers_interaction_over_position", function()
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonalityModule = require("ai_tournament.mid_personality")
    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonalityModule.interpretMap
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
    }
    local attacks = {
        {type = "attack", unit = {row = 4, col = 1}, target = {row = 4, col = 6}}
    }
    local context = ctxWith(firstMoves, secondMoves, attacks)
    local map = midMap(0)
    local personality = midPersonality()
    map.byKey["4,4"].value = 12000
    personality.byKey["4,4"].value = 12000
    local state = stateWith(0)
    state.turnsWithoutDamage = 3
    state.units[#state.units + 1] = unit("Artillery", 1, 4, 1, {atkRange = 5, atkDamage = 1, move = 0})

    local ok, err = pcall(function()
        midPositionMap.build = function()
            return map
        end
        midPersonalityModule.interpretMap = function()
            return personality
        end

        local result = require("ai_tournament.pipeline_v2_mid").run(mkAI(), state, context, {}, {})
        assertTrue(result and result.item, "pipeline should return a mid candidate")
        assertEquals(result.item.candidate.source, "mid_v2_attack", "draw -2 should prefer accepted interaction")
        assertTrue(result.item.candidate.containsAttack == true, "selected candidate should interact")
        assertEquals(context.stats.pipelineV2MidDrawPressureNearLimit, true)
        assertEquals(context.stats.pipelineV2MidDrawPressureStreak, 3)
    end)

    midPositionMap.build = originalBuild
    midPersonalityModule.interpretMap = originalInterpret
    if not ok then
        error(err, 0)
    end
end)

runTest("mid_score_draw_pressure_rewards_approach_without_veto", function()
    local midScore = require("ai_tournament.mid_score")
    local context = ctxWith({}, {})
    local before = stateWith(0)
    before.turnsWithoutDamage = 1
    before.currentTurn = 11
    before.turnNumber = 11
    before.units = {
        unit("Crusher", 1, 2, 2, {currentHp = 4, startingHp = 4}),
        unit("Earthstalker", 2, 6, 6, {currentHp = 3, startingHp = 3})
    }
    local after = clone(before)
    after.units[1].row = 4
    after.units[1].col = 4
    local candidate = {
        signature = "draw_approach",
        containsAttack = false,
        containsDeploy = false,
        actions = {
            {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
        },
        midPosition = {
            accepted = true,
            score = 10,
            pressureGain = 0,
            targetValue = 0,
            reason = "test_approach"
        },
        tacticalTags = {}
    }

    local score = midScore.score(mkAI(), before, context, candidate, {afterOur = after})

    assertTrue(score.breakdown.midDrawPressure ~= nil, "draw pressure breakdown should be present")
    assertTrue(score.breakdown.midDrawPressure.hasInteraction == false, "candidate should remain non-interactive")
    assertTrue(
        score.breakdown.midDrawPressure.approach
            and score.breakdown.midDrawPressure.approach.progress > 0,
        "approach progress should be scored"
    )
    assertEquals(candidate.tacticalTags.drawApproachProgress, 4)
end)

runTest("endgame_draw_closure_rewards_unit_progress_when_global_closest_is_static", function()
    local midScore = require("ai_tournament.mid_score")
    local context = ctxWith({}, {})
    context.pipelineV2EndRuntime = true
    context.phase = {
        name = "endgame",
        endgame = true,
        mid = false,
        early = false,
        reason = "supply_empty_both",
        supply = {[1] = 0, [2] = 0}
    }
    context.stats.legalAttackActions = 0
    context.stats.legalMoveAttackActions = 0
    context.cfg.PIPELINE_V2_ENDGAME_DRAW_CLOSURE_ENABLED = true
    context.cfg.PIPELINE_V2_ENDGAME_DRAW_CLOSURE_PROGRESS_BONUS = 2200
    context.cfg.PIPELINE_V2_ENDGAME_DRAW_CLOSURE_STAGNATION_PENALTY = 3500

    local before = stateWith(0)
    before.currentTurn = 44
    before.turnNumber = 44
    before.turnsWithoutDamage = 4
    before.units = {
        unit("Crusher", 1, 3, 3, {currentHp = 4, startingHp = 4}),
        unit("Wingstalker", 1, 1, 1, {currentHp = 3, startingHp = 3}),
        unit("Earthstalker", 2, 3, 5, {currentHp = 3, startingHp = 3}),
        unit("Bastion", 2, 8, 8, {currentHp = 6, startingHp = 6})
    }

    local afterAdvance = clone(before)
    afterAdvance.units[2].row = 4
    afterAdvance.units[2].col = 4

    local advancing = {
        signature = "end_draw_close",
        containsAttack = false,
        containsDeploy = false,
        actions = {
            {type = "move", unit = {row = 1, col = 1}, target = {row = 4, col = 4}}
        },
        midPosition = {
            accepted = true,
            score = 0,
            pressureGain = 0,
            targetValue = 0,
            reason = "test_end_draw_close",
            drawApproachProgress = 4
        },
        tacticalTags = {}
    }
    local stagnant = clone(advancing)
    stagnant.signature = "end_draw_stagnant"
    stagnant.midPosition.drawApproachProgress = 0

    local advanceScore = midScore.score(mkAI(), before, context, advancing, {afterOur = afterAdvance})
    local stagnantScore = midScore.score(mkAI(), before, context, stagnant, {afterOur = before})

    assertTrue(
        advanceScore.breakdown.endgameDrawClosure ~= nil,
        "endgame draw closure should be visible in score breakdown"
    )
    assertEquals(advanceScore.breakdown.endgameDrawClosure.actionProgress, 4)
    assertEquals(advanceScore.breakdown.endgameDrawClosure.globalProgress, 0)
    assertTrue(
        advanceScore.force > stagnantScore.force,
        "unit-level closure progress should outrank stagnant endgame positioning"
    )
end)

runTest("mid_score_draw_pressure_does_not_promote_suicide_chip_over_good_approach", function()
    local midScore = require("ai_tournament.mid_score")
    local context = ctxWith({}, {})
    context.cfg.PIPELINE_V2_MID_DRAW_SUICIDE_CHIP_FORCE_PENALTY = 80000
    local before = stateWith(0)
    before.turnsWithoutDamage = 3
    before.currentTurn = 11
    before.turnNumber = 11
    before.units = {
        unit("Crusher", 1, 2, 2, {currentHp = 4, startingHp = 4}),
        unit("Earthstalker", 2, 6, 6, {currentHp = 3, startingHp = 3})
    }
    local afterApproach = clone(before)
    afterApproach.units[1].row = 5
    afterApproach.units[1].col = 5

    local approachCandidate = {
        signature = "draw_approach_good",
        containsAttack = false,
        containsDeploy = false,
        actions = {
            {type = "move", unit = {row = 2, col = 2}, target = {row = 5, col = 5}}
        },
        midPosition = {
            accepted = true,
            score = 10,
            pressureGain = 0,
            targetValue = 0,
            reason = "test_approach"
        },
        tacticalTags = {}
    }
    local suicideChipCandidate = {
        signature = "draw_suicide_chip",
        containsAttack = true,
        containsDeploy = false,
        actions = {
            {type = "attack", unit = {row = 2, col = 2}, target = {row = 6, col = 6}}
        },
        midTrade = {
            accepted = true,
            reason = "mid_trade_legal_damage_candidate",
            class = "legal_damage",
            factionAttackCount = 1,
            totalDamage = 1,
            kills = 0,
            commandantDamage = 0,
            materialDelta = -80,
            inflictedMaterial = 8,
            hpTradeNet = -20,
            expectedLoss = 80,
            counterCredit = 0,
            legalDamageCandidate = true,
            drawSuicideChip = true
        },
        tacticalTags = {}
    }

    local approachScore = midScore.score(mkAI(), before, context, approachCandidate, {
        afterOur = afterApproach
    })
    local suicideScore = midScore.score(mkAI(), before, context, suicideChipCandidate, {
        afterOur = before
    })

    assertTrue(approachScore.force > suicideScore.force, "good approach should outrank weak suicide chip at draw -2")
    assertTrue(
        suicideScore.breakdown.midDrawSuicideChipPenalty ~= nil,
        "suicide chip draw penalty should be visible"
    )
end)

runTest("mid_position_draw_no_legal_attack_scans_approach_without_veto", function()
    local generator = require("ai_tournament.mid_position_candidates")
    local firstMoves = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 2, col = 3}},
        {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
    }
    local secondMoves = {
        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
    }
    local context = ctxWith(firstMoves, secondMoves)
    context.stats.legalAttackActions = 0
    context.stats.legalMoveAttackActions = 0
    context.cfg.PIPELINE_V2_MID_POSITION_SCAN_CAP = 1
    context.cfg.PIPELINE_V2_MID_DRAW_APPROACH_SCAN_CAP = 8
    context.cfg.PIPELINE_V2_MID_DRAW_APPROACH_PRESCORE_BONUS = 450
    context.midPersonality = midPersonality()

    local map = midMap(0)
    map.byKey["2,3"] = {
        key = "2,3",
        row = 2,
        col = 3,
        value = 620,
        status = "pressure_cell",
        free = true,
        reachable = true,
        enemyPunish = {damage = 0, lethal = false},
        coveredIfOccupied = true
    }
    context.midPersonality.byKey["2,3"] = {
        key = "2,3",
        row = 2,
        col = 3,
        value = 620,
        status = "pressure_cell",
        acceptedForMid = true,
        intent = "pressure",
        riskBand = "stable"
    }
    map.byKey["4,4"].value = 20
    context.midPersonality.byKey["4,4"].value = 20

    local state = stateWith(0)
    state.turnsWithoutDamage = 3
    state.units = {
        unit("Crusher", 1, 2, 2, {currentHp = 4, startingHp = 4}),
        unit("Wingstalker", 1, 1, 1),
        unit("Earthstalker", 2, 6, 6, {currentHp = 3, startingHp = 3})
    }

    local candidates = generator.generate(mkAI(), state, context, map, {})

    assertTrue(#candidates >= 1, "draw approach should keep legal movement candidates")
    assertEquals(candidates[1].actions[1].target.row, 4)
    assertEquals(candidates[1].actions[1].target.col, 4)
    assertTrue(
        tostring(candidates[1].midPosition.reason or ""):find("mid_position_draw_approach", 1, true) ~= nil,
        "draw approach reason should survive second-action annotation"
    )
    assertEquals(candidates[1].midPosition.drawApproachProgress, 4)
    assertEquals(context.stats.pipelineV2MidDrawApproachNoLegalCombat, true)
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
        print(string.format("[PASS] %s (%.2f ms)", result.name, result.ms))
    else
        print(string.format("[FAIL] %s (%.2f ms)", result.name, result.ms))
        print(result.err)
    end
end

print(string.format("ai_tournament_mid_position_candidates_smoke passed: %d/%d", passed, #results))
if passed ~= #results then
    os.exit(1)
end
