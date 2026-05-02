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

local function ensureHeadlessGlobals()
    _G.love = _G.love or {}
    love.timer = love.timer or {}
    love.timer.getTime = love.timer.getTime or os.clock
    love.audio = love.audio or {}
    love.audio.newSource = love.audio.newSource or function()
        local source = {}
        function source:clone() return self end
        function source:play() end
        function source:stop() end
        function source:seek() end
        function source:setVolume() end
        function source:setPitch() end
        return source
    end

    _G.SETTINGS = _G.SETTINGS or {
        PERF = {
            LOG_LEVEL = "warn",
            LOG_CATEGORIES = {
                AI = false,
                GAMEPLAY = false,
                GRID = false,
                UI = false,
                PERF = false
            }
        },
        AUDIO = {
            SFX = false,
            SFX_VOLUME = 0
        },
        DISPLAY = {
            WIDTH = 1280,
            HEIGHT = 720,
            SCALE = 1,
            OFFSETX = 0,
            OFFSETY = 0
        }
    }

    _G.DEBUG = _G.DEBUG or {}
    DEBUG.AI = false

    _G.GAME = _G.GAME or {}
    GAME.CONSTANTS = GAME.CONSTANTS or {}
    GAME.CONSTANTS.GRID_SIZE = GAME.CONSTANTS.GRID_SIZE or 8
    GAME.CONSTANTS.MAX_ACTIONS_PER_TURN = GAME.CONSTANTS.MAX_ACTIONS_PER_TURN or 2
    GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE = GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE or 10
    GAME.MODE = GAME.MODE or {
        AI_VS_AI = "ai_vs_ai"
    }
    GAME.CURRENT = GAME.CURRENT or {}
    GAME.CURRENT.TURN = GAME.CURRENT.TURN or 13
    GAME.CURRENT.MODE = GAME.CURRENT.MODE or GAME.MODE.AI_VS_AI
    GAME.CURRENT.AI_PLAYER_NUMBER = GAME.CURRENT.AI_PLAYER_NUMBER or 1
    GAME.getAIFactionId = GAME.getAIFactionId or function()
        return GAME.CURRENT.AI_PLAYER_NUMBER or 1
    end
    GAME.isFactionControlledByAI = GAME.isFactionControlledByAI or function()
        return true
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
        Artillery = 5,
        Rock = 5
    })[name] or 3
    local out = {
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = hp,
        startingHp = hp,
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

local function stateWith(units, neutralBuildings)
    return {
        currentPlayer = 1,
        currentTurn = 11,
        turnNumber = 11,
        gridSize = 8,
        units = units or {},
        neutralBuildings = neutralBuildings or {},
        commandHubs = {
            [1] = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
            [2] = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12}
        },
        supply = {
            [1] = {},
            [2] = {}
        }
    }
end

local function supply(name)
    local hp = ({
        Wingstalker = 3,
        Crusher = 4,
        Bastion = 6,
        Cloudstriker = 4,
        Earthstalker = 3,
        Healer = 4,
        Artillery = 5
    })[name] or 3
    return {
        name = name,
        currentHp = hp,
        startingHp = hp
    }
end

local function getUnitAt(state, row, col)
    for _, item in ipairs(state.units or {}) do
        if item and item.row == row and item.col == col then
            return item
        end
    end
    for playerId, hub in pairs(state.commandHubs or {}) do
        if hub and hub.row == row and hub.col == col then
            return {
                name = "Commandant",
                player = playerId,
                row = row,
                col = col,
                currentHp = hub.currentHp,
                startingHp = hub.startingHp
            }
        end
    end
    for _, rock in ipairs(state.neutralBuildings or {}) do
        if rock and rock.row == row and rock.col == col then
            return {
                name = "Rock",
                player = 0,
                row = row,
                col = col,
                currentHp = rock.currentHp or 5,
                startingHp = rock.startingHp or 5
            }
        end
    end
    return nil
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

local function removeUnitAt(state, row, col)
    for index = #((state and state.units) or {}), 1, -1 do
        local item = state.units[index]
        if item and item.row == row and item.col == col then
            table.remove(state.units, index)
            return
        end
    end
end

local function applyAction(ai, state, action)
    if not (state and action and action.type and action.type ~= "skip") then
        return
    end
    local actor = action.unit and getUnitAt(state, action.unit.row, action.unit.col) or nil
    if action.type == "move" and actor and action.target then
        actor.row = action.target.row
        actor.col = action.target.col
        actor.hasMoved = true
        actor.actionsUsed = (actor.actionsUsed or 0) + 1
    elseif action.type == "attack" and actor and action.target then
        local target = getUnitAt(state, action.target.row, action.target.col)
        if target then
            local damage = ai:calculateDamage(actor, target)
            target.currentHp = math.max(0, (target.currentHp or target.startingHp or 0) - damage)
            actor.hasActed = true
            actor.actionsUsed = (actor.actionsUsed or 0) + 1
            if target.currentHp <= 0 and target.player ~= nil and target.player > 0 and target.name ~= "Commandant" then
                removeUnitAt(state, action.target.row, action.target.col)
            end
        end
    end
end

local function simulate(ai, state, actions)
    local nextState = clone(state)
    for _, action in ipairs(actions or {}) do
        applyAction(ai, nextState, action)
    end
    return nextState
end

local function mkAI(reference)
    local values = {
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
    return {
        aiReference = reference,
        getOpponentPlayer = function(_, playerId)
            return playerId == 1 and 2 or 1
        end,
        isHubUnit = function(_, item)
            return item and item.name == "Commandant"
        end,
        isObstacleUnit = function(_, item)
            return item and (item.player == 0 or item.name == "Rock")
        end,
        getUnitAtPosition = function(_, state, row, col)
            return getUnitAt(state, row, col)
        end,
        calculateDamage = function(_, attacker)
            return attacker and attacker.atkDamage or 0
        end,
        getUnitBaseValue = function(_, item)
            return item and values[item.name] or 25
        end
    }
end

local function signature(action)
    if action.type == "attack" or action.type == "move" or action.type == "repair" then
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

local function ctxWith(firstActions, reference, secondActions)
    return {
        aiPlayer = 1,
        enemyPlayer = 2,
        aiReference = reference or "maggie",
        phase = {name = "mid", mid = true, early = false},
        cfg = {
            PIPELINE_V2_MID_ENABLED = true,
            PIPELINE_V2_MID_ATTACK_CANDIDATES_ENABLED = true,
            PIPELINE_V2_MID_ATTACK_SCAN_CAP = 8,
            PIPELINE_V2_MID_ATTACK_CANDIDATE_CAP = 4,
            PIPELINE_V2_MID_MOVE_ATTACK_CANDIDATES_ENABLED = true,
            PIPELINE_V2_MID_MOVE_ATTACK_SCAN_CAP = 8,
            PIPELINE_V2_MID_SECOND_ACTION_ENABLED = true,
            PIPELINE_V2_MID_SECOND_SCAN_CAP = 6,
            PIPELINE_V2_MID_SECOND_COMPLETION_CAP = 2,
            PIPELINE_V2_MID_MAX_RANKED = 4,
            PIPELINE_V2_MID_MAX_FINALISTS = 2
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
                local sourceActions = firstActions or {}
                if opts
                    and opts.includeMove ~= false
                    and opts.includeAttack ~= false
                    and opts.includeRepair ~= false
                    and opts.includeDeploy ~= false then
                    sourceActions = secondActions or {}
                end
                local out = {}
                for _, action in ipairs(sourceActions) do
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

local function midMap()
    return {
        byKey = {
            ["4,4"] = {
                row = 4,
                col = 4,
                key = "4,4",
                value = 260,
                status = "enemy_occupied",
                attackableEnemy = true,
                compactReasons = {"mid_attackable_enemy"}
            },
            ["5,5"] = {
                row = 5,
                col = 5,
                key = "5,5",
                value = 20,
                status = "blocked",
                attackableEnemy = false,
                compactReasons = {"mid_occupancy"}
            }
        }
    }
end

local function midPersonality()
    local profile = require("ai_tournament.mid_personality").resolve(nil, nil, {aiReference = "maggie"}, "maggie")
    return {
        profile = profile,
        byKey = {
            ["4,4"] = {
                key = "4,4",
                value = 320,
                status = "enemy_occupied"
            },
            ["5,5"] = {
                key = "5,5",
                value = 15,
                status = "blocked"
            }
        }
    }
end

runTest("mid_attack_candidates_emit_only_trade_accepted_attacks", function()
    local generator = require("ai_tournament.mid_attack_candidates")
    local trade = require("ai_tournament.mid_trade_model")
    local attackActions = {
        {type = "attack", unit = {row = 4, col = 1}, target = {row = 4, col = 4}},
        {type = "attack", unit = {row = 4, col = 1}, target = {row = 5, col = 5}}
    }
    local secondActions = {
        {type = "move", unit = {row = 2, col = 1}, target = {row = 2, col = 2}}
    }
    local context = ctxWith(attackActions, "maggie", secondActions)
    context.midPersonality = midPersonality()
    local candidates = generator.generate(mkAI("maggie"), stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 3}),
        unit("Wingstalker", 1, 2, 1, {move = 2}),
        unit("Bastion", 2, 4, 4, {atkRange = 1, atkDamage = 2, move = 0})
    }, {
        {row = 5, col = 5}
    }), context, midMap(), trade, {})

    assertEquals(#candidates, 1, "only the faction trade should survive")
    assertEquals(candidates[1].source, "mid_v2_attack", "candidate should be marked as mid V2")
    assertEquals(#candidates[1].actions, 2, "mid V2 attack candidates should be complete turns")
    assertTrue(candidates[1].completeTurn == true, "mid V2 attack candidate should be marked complete")
    assertTrue(candidates[1].midTrade and candidates[1].midTrade.accepted == true, "candidate should carry accepted trade data")
    assertEquals(context.stats.pipelineV2MidAttackCandidates, 1, "stats should expose accepted attack candidates")
    assertTrue((context.stats.pipelineV2MidSecondCompleted or 0) >= 1, "second action completion should be logged")
    assertEquals(context.stats.pipelineV2MidAttackRejectedReasons.mid_trade_not_faction_attack, 1, "rock attack should be rejected")
end)

runTest("mid_attack_candidates_keep_prefix_attack_with_least_bad_second_action", function()
    local generator = require("ai_tournament.mid_attack_candidates")
    local attackActions = {
        {type = "attack", unit = {row = 4, col = 1}, target = {row = 4, col = 4}}
    }
    local secondActions = {
        {type = "move", unit = {row = 2, col = 1}, target = {row = 2, col = 2}}
    }
    local context = ctxWith(attackActions, "maggie", secondActions)
    context.midPersonality = midPersonality()
    local ai = mkAI("maggie")
    local state = stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 3}),
        unit("Wingstalker", 1, 2, 1, {move = 2}),
        unit("Bastion", 2, 4, 4, {atkRange = 1, atkDamage = 2, move = 0})
    })
    local tradeModel = {
        evaluateAttack = function(_, stateArg, _, candidate)
            local actions = candidate and candidate.actions or {}
            local accepted = #actions <= 1
            return {
                accepted = accepted,
                reason = accepted and "mid_trade_supported_pressure" or "mid_trade_below_material_threshold",
                class = accepted and "pressure" or "rejected",
                score = accepted and 500 or -500,
                afterState = simulate(ai, stateArg, actions),
                totalDamage = 3,
                factionAttackCount = 1,
                kills = 0,
                commandantDamage = 0,
                materialDelta = accepted and 40 or -40,
                hpTradeNet = 3,
                expectedLoss = accepted and 0 or 70,
                counterCredit = 0,
                compactReasons = {accepted and "mid_trade_supported_pressure" or "mid_trade_below_material_threshold"}
            }
        end
    }

    local candidates = generator.generate(ai, state, context, midMap(), tradeModel, {})

    assertEquals(#candidates, 1, "accepted attack prefix should survive with a legal second action")
    assertTrue(candidates[1].tacticalTags.midSecondFallback == true, "candidate should expose second-action fallback")
    assertEquals(candidates[1].midSecondReason, "mid_second_prefix_trade_fallback")
    assertEquals(context.stats.pipelineV2MidSecondFallbackCompletions, 1)
end)

runTest("mid_attack_candidates_recover_attack_prefix_when_only_second_attack_rejects", function()
    local generator = require("ai_tournament.mid_attack_candidates")
    local attackActions = {
        {type = "attack", unit = {row = 4, col = 1}, target = {row = 4, col = 4}}
    }
    local secondActions = {
        {type = "attack", unit = {row = 2, col = 1}, target = {row = 2, col = 2}}
    }
    local context = ctxWith(attackActions, "maggie", secondActions)
    context.midPersonality = midPersonality()
    context.cfg.PIPELINE_V2_MID_SECOND_PREFIX_RECOVERY_SCAN_CAP = 4
    local ai = mkAI("maggie")
    local state = stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 3}),
        unit("Wingstalker", 1, 2, 1, {atkRange = 1, atkDamage = 2}),
        unit("Earthstalker", 2, 2, 2, {atkRange = 1, atkDamage = 2}),
        unit("Bastion", 2, 4, 4, {atkRange = 1, atkDamage = 2, move = 0})
    })
    local tradeModel = {
        evaluateAttack = function(_, stateArg, _, candidate)
            local actions = candidate and candidate.actions or {}
            local accepted = #actions <= 1
            return {
                accepted = accepted,
                reason = accepted and "mid_trade_supported_pressure" or "mid_trade_second_attack_unproven",
                class = accepted and "pressure" or "rejected",
                score = accepted and 520 or -600,
                afterState = simulate(ai, stateArg, actions),
                totalDamage = 3,
                factionAttackCount = 1,
                kills = 0,
                commandantDamage = 0,
                materialDelta = accepted and 45 or -60,
                hpTradeNet = 3,
                expectedLoss = accepted and 0 or 80,
                counterCredit = 0,
                compactReasons = {accepted and "mid_trade_supported_pressure" or "mid_trade_second_attack_unproven"}
            }
        end
    }

    local candidates = generator.generate(ai, state, context, midMap(), tradeModel, {})

    assertEquals(#candidates, 1, "accepted attack prefix should survive even when the only second action is an unproven attack")
    assertEquals(candidates[1].midSecondReason, "mid_second_prefix_trade_recovery")
    assertTrue(candidates[1].tacticalTags.midSecondFallback == true, "recovery should still be marked as a technical fallback")
    assertTrue(candidates[1].tacticalTags.midSecondRecovery == true, "candidate should expose prefix recovery")
    assertEquals(context.stats.pipelineV2MidSecondPrefixRecoveryCompletions, 1)
    assertEquals(context.stats.pipelineV2MidAttackRejectedReasons.mid_no_second_action, nil)
end)

runTest("mid_attack_candidates_emit_move_attack_trade_candidates", function()
    local generator = require("ai_tournament.mid_attack_candidates")
    local trade = require("ai_tournament.mid_trade_model")
    local moveActions = {
        {type = "move", unit = {row = 4, col = 2}, target = {row = 4, col = 3}}
    }
    local attackAfterMove = {
        {type = "attack", unit = {row = 4, col = 3}, target = {row = 4, col = 4}}
    }
    local context = ctxWith({}, "maggie", {})
    context.midPersonality = midPersonality()
    context.turnEnumerator.collectTournamentActions = function(_, stateArg, _, _, opts)
        local out = {}
        local sourceActions = {}
        if opts and opts.includeMove ~= false and opts.includeAttack == false then
            sourceActions = moveActions
        elseif opts and opts.includeMove == false and opts.includeAttack ~= false then
            sourceActions = getUnitAt(stateArg, 4, 3) and attackAfterMove or {}
        end
        for _, action in ipairs(sourceActions) do
            out[#out + 1] = {
                action = action,
                signature = signature(action),
                cheapScore = 0
            }
        end
        return out
    end

    local candidates = generator.generate(mkAI("maggie"), stateWith({
        unit("Crusher", 1, 4, 2, {move = 1, atkRange = 1, atkDamage = 3}),
        unit("Wingstalker", 2, 4, 4, {atkRange = 1, atkDamage = 2})
    }), context, midMap(), trade, {})

    assertEquals(#candidates, 1, "move+attack trade should be emitted as a complete mid candidate")
    assertEquals(candidates[1].source, "mid_v2_move_attack", "candidate should expose move+attack source")
    assertEquals(#candidates[1].actions, 2, "move+attack consumes the full two-action turn")
    assertEquals(candidates[1].actions[1].type, "move", "first action should be the move prefix")
    assertEquals(candidates[1].actions[2].type, "attack", "second action should be the attack")
    assertTrue(candidates[1].completeTurn == true, "move+attack candidate should already be complete")
    assertTrue(candidates[1].hasFactionAttack == true, "move+attack should be marked as faction combat")
    assertEquals(candidates[1].combatValue.kills, 1, "combat value should preserve the trade kill")
    assertEquals(context.stats.pipelineV2MidMoveAttackEvaluated, 1, "stats should expose evaluated move+attack trades")
    assertEquals(context.stats.pipelineV2MidMoveAttackCandidates, 1, "stats should expose accepted move+attack candidates")
end)

runTest("pipeline_v2_mid_selects_accepted_mid_attack", function()
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonalityModule = require("ai_tournament.mid_personality")
    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonalityModule.interpretMap

    local attackActions = {
        {type = "attack", unit = {row = 4, col = 1}, target = {row = 4, col = 4}}
    }
    local secondActions = {
        {type = "move", unit = {row = 2, col = 1}, target = {row = 2, col = 2}}
    }
    local context = ctxWith(attackActions, "maggie", secondActions)
    local map = midMap()
    local personality = midPersonality()
    local ok, err = pcall(function()
        midPositionMap.build = function()
            return map
        end
        midPersonalityModule.interpretMap = function()
            return personality
        end

        local pipeline = require("ai_tournament.pipeline_v2_mid")
        local result = pipeline.run(mkAI("maggie"), stateWith({
            unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 3}),
            unit("Wingstalker", 1, 2, 1, {move = 2}),
            unit("Bastion", 2, 4, 4, {atkRange = 1, atkDamage = 2, move = 0})
        }), context, {}, {})

        assertTrue(result and result.item, "pipeline should select the accepted mid attack")
        assertEquals(result.reason, "pipeline_v2_mid_selected", "pipeline should report a real mid selection")
        assertEquals(#result.item.candidate.actions, 2, "pipeline should select a complete two-action turn")
        assertEquals(context.stats.pipelineV2MidAccepted, 1, "gate should accept the mid trade")
        assertEquals(context.stats.pipelineV2MidFellThroughToTournament, false, "selected mid should not fall through")
    end)

    midPositionMap.build = originalBuild
    midPersonalityModule.interpretMap = originalInterpret
    if not ok then
        error(err, 0)
    end
end)

runTest("brain_uses_pipeline_v2_mid_attack_in_real_turn_path", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.TURN = 13
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local AI = require("ai")
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local state = fixtureLib.buildBaseState({
        actingPlayer = 1,
        currentPlayer = 1,
        turnNumber = 13,
        currentTurn = 13,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 4, col = 8, currentHp = 12, startingHp = 12},
        units = {
            unit("Cloudstriker", 1, 4, 5),
            unit("Wingstalker", 1, 2, 1),
            unit("Bastion", 2, 8, 8, {move = 0})
        },
        neutralBuildings = {},
        supply = {
            [1] = {supply("Bastion")},
            [2] = {supply("Bastion")}
        }
    })

    local ai = AI.new({factionId = 1})
    ai.grid = {
        getUnitAt = function()
            return nil
        end
    }

    local sequence, meta = require("ai_tournament.brain").chooseTurn(ai, state, {
        maxActions = 2,
        decisionStartTime = love.timer.getTime(),
        softBudgetMs = 900,
        hardBudgetMs = 1200
    })
    local stats = meta and meta.stats or {}

    assertTrue(sequence and (sequence[1] and sequence[1].type == "attack"
        or sequence[2] and sequence[2].type == "attack"), "real turn should return a mid attack")
    assertEquals(#sequence, 2, "real mid path should return a full two-action turn")
    assertEquals(stats.coreExit, "pipeline_v2_mid_selected", "brain should exit through real mid V2")
    assertTrue((stats.pipelineV2MidAccepted or 0) >= 1, "mid gate should accept at least one complete mid trade")
    assertEquals(tonumber(stats.sanitizerReplacements) or 0, 0, "mid V2 should not need sanitizer replacement")
    assertEquals(stats.pipelineV2MidSelectedTradeReason, "mid_trade_supported_pressure", "trade reason should be logged")
    assertTrue(stats.pipelineV2MidSelectedSource == "mid_v2_attack"
        or stats.pipelineV2MidSelectedSource == "mid_v2_move_attack", "selected source should stay inside mid attack V2")
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

print(string.format("ai_tournament_mid_attack_candidates_smoke passed: %d/%d", passed, #results))
if passed ~= #results then
    os.exit(1)
end
