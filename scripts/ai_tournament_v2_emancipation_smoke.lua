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
        error(string.format("%s: expected %s, got %s", message or "assertEquals failed", tostring(expected), tostring(actual)), 2)
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
        AI_VS_AI = "ai_vs_ai",
        MULTYPLAYER_LOCAL = "multi_local",
        MULTYPLAYER_NET = "multi_net"
    }

    GAME.CURRENT = GAME.CURRENT or {}
    GAME.CURRENT.TURN = GAME.CURRENT.TURN or 1
    GAME.CURRENT.MODE = GAME.CURRENT.MODE or GAME.MODE.AI_VS_AI
    GAME.CURRENT.AI_PLAYER_NUMBER = GAME.CURRENT.AI_PLAYER_NUMBER or 1

    GAME.getAIFactionId = GAME.getAIFactionId or function()
        return GAME.CURRENT.AI_PLAYER_NUMBER or 1
    end

    GAME.isFactionControlledByAI = GAME.isFactionControlledByAI or function()
        return true
    end
end

local function mkAI(factionId)
    local AI = require("ai")
    local ai = AI.new({factionId = factionId})
    ai.grid = {
        getUnitAt = function()
            return nil
        end
    }
    return ai
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
        hasActed = false,
        hasMoved = false,
        actionsUsed = 0
    }
    for key, value in pairs(overrides or {}) do
        out[key] = value
    end
    return out
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

local function baseState(opts)
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    opts = opts or {}
    return fixtureLib.buildBaseState({
        actingPlayer = opts.actingPlayer or 1,
        currentPlayer = opts.actingPlayer or 1,
        turnNumber = opts.turnNumber or 1,
        currentTurn = opts.currentTurn or opts.turnNumber or 1,
        turnsWithoutDamage = opts.turnsWithoutDamage or 0,
        playerOneHub = opts.playerOneHub or {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 12, startingHp = 12},
        playerTwoHub = opts.playerTwoHub or {name = "Commandant", player = 2, row = 7, col = 7, currentHp = 12, startingHp = 12},
        units = opts.units or {},
        neutralBuildings = opts.neutralBuildings or {
            {row = 3, col = 4},
            {row = 4, col = 5},
            {row = 5, col = 4},
            {row = 6, col = 5}
        },
        supply = opts.supply or {
            [1] = {supply("Bastion"), supply("Cloudstriker"), supply("Artillery")},
            [2] = {supply("Bastion"), supply("Earthstalker"), supply("Wingstalker")}
        }
    })
end

local function choose(ai, state)
    local brain = require("ai_tournament.brain")
    local sequence, meta = brain.chooseTurn(ai, state, {
        maxActions = 2,
        decisionStartTime = love.timer.getTime(),
        softBudgetMs = 900,
        hardBudgetMs = 1200
    })
    assertTrue(type(sequence) == "table" and #sequence > 0, "expected V2/hard path to return a sequence")
    assertTrue(type(meta) == "table", "expected tournament metadata")
    return sequence, meta
end

local function earlyBuildPositionState()
    return baseState({
        actingPlayer = 2,
        turnNumber = 1,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 5, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 7, col = 2, currentHp = 12, startingHp = 12},
        units = {
            unit("Crusher", 1, 4, 5, {hasMoved = true, actionsUsed = 1}),
            unit("Cloudstriker", 1, 1, 4, {actionsUsed = 1}),
            unit("Crusher", 2, 7, 3)
        },
        neutralBuildings = {
            {row = 3, col = 7},
            {row = 4, col = 1},
            {row = 5, col = 6},
            {row = 6, col = 1}
        },
        supply = {
            [1] = {supply("Wingstalker"), supply("Bastion")},
            [2] = {
                supply("Wingstalker"),
                supply("Crusher"),
                supply("Bastion"),
                supply("Cloudstriker"),
                supply("Earthstalker"),
                supply("Healer"),
                supply("Artillery")
            }
        }
    })
end

local function pureCombatState()
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    return fixtureLib.buildBaseState({
        actingPlayer = 1,
        turnNumber = 3,
        turnsWithoutDamage = 0,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            unit("Crusher", 1, 4, 4),
            unit("Wingstalker", 1, 1, 2),
            unit("Bastion", 2, 4, 5),
            unit("Bastion", 2, 6, 6),
            unit("Cloudstriker", 2, 6, 5),
            unit("Earthstalker", 2, 7, 6)
        },
        supplyOne = {supply("Bastion")},
        supplyTwo = {supply("Bastion")}
    })
end

local function immediateDefenseState()
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local fixture = fixtureLib.getFixture("immediate_commandant_defense")
    assertTrue(fixture and fixture.state, "expected immediate defense fixture")
    fixture.state.turnNumber = 3
    fixture.state.currentTurn = 3
    fixture.state.supply = {
        [1] = {supply("Bastion")},
        [2] = {supply("Bastion")}
    }
    return fixture.state
end

local function isEarlyPositionSource(source)
    source = tostring(source or "")
    return source == "early_position_deploy_first" or source == "early_position_move"
end

local function assertNoNormalFullTurnCompetition(stats)
    local stageMs = stats.stageMs or {}
    assertTrue((tonumber(stats.normalFullTurnCandidates) or 0) == 0, "normal full-turn candidates should not be generated")
    assertTrue((tonumber(stats.ownCandidates) or 0) == 0, "legacy own-candidate pool should not compete in V2-selected early")
    assertTrue(stageMs.enumeration == nil or (tonumber(stageMs.enumeration) or 0) == 0, "normal enumeration stage should not run")
    assertTrue((stats.rankedSourceCountsBeforeGate or {}).full_turn == nil, "full_turn must not appear before early gate")
    assertTrue((stats.rankedSourceCountsAfterGate or {}).full_turn == nil, "full_turn must not appear after early gate")
end

local function assertNoLegacyEarlyGateRejection(stats)
    local rejected = stats.pipelineV2RejectedReasons or {}
    assertTrue(
        rejected.early_move_attack_trap_prefix_without_tactical_proof == nil,
        "V2 gate should not use legacy early move-attack-trap prefix rejection"
    )
    assertTrue(
        rejected.early_response_move_attack_trap_prefix_without_tactical_proof == nil,
        "V2 gate should not use legacy early response move-attack-trap prefix rejection"
    )
end

runTest("v2_only_runtime_defaults_are_unambiguous", function()
    local tournament = require("ai_config").AI_PARAMS.TOURNAMENT_AI

    assertTrue(tournament.ENABLED == true, "tournament AI should be enabled by default")
    assertTrue(tournament.FALLBACK_TO_LEGACY == nil, "runtime should not expose legacy fallback")
    assertTrue(tournament.PIPELINE_V2_ENABLED == true, "pipeline V2 should be enabled by default")
    assertTrue(tournament.PIPELINE_V2_SELECT_ENABLED == true, "pipeline V2 selection should be enabled by default")
    assertTrue(tournament.PIPELINE_V2_FALLBACK_TO_V1 == nil, "V2 should not expose a V1 fallthrough flag")
    assertTrue(
        tournament.PIPELINE_V2_SOFT_DEFENSE_PRESSURE_SCORING_ENABLED == true,
        "soft DEFEND_NOW pressure should be scored inside V2"
    )
    assertTrue(
        tournament.PIPELINE_V2_SOFT_DEFENSE_SOURCE_SCORING_ENABLED == true,
        "soft DEFEND_NOW pressure should score whether the active source was answered"
    )
    assertEquals(
        tournament.PIPELINE_V2_SOFT_DEFENSE_OFF_SOURCE_ATTACK_PENALTY,
        9000,
        "attacking away from an active pressure source should be a score penalty, not a veto"
    )
    assertEquals(
        tournament.PIPELINE_V2_SOFT_DEFENSE_RANGED_DUEL_NONREDUCING_PENALTY,
        2800,
        "non-reducing ranged duels should be softly discouraged"
    )
    assertTrue(
        tournament.PIPELINE_V2_SOFT_DEFENSE_RANGED_RESPONSE_ENABLED == true,
        "ranged pressure response scoring should be explicit and toggleable"
    )
    assertEquals(
        tournament.PIPELINE_V2_SOFT_DEFENSE_RANGED_DUEL_FUTILE_PENALTY,
        7000,
        "futile ranged answers should lose score without becoming illegal"
    )
    assertEquals(
        tournament.PIPELINE_V2_MID_SOFT_DEFENSE_PRESSURE_SCALE,
        0.55,
        "mid soft defense pressure should be scaled so it guides scoring without dominating legal play"
    )
    assertEquals(
        tournament.PIPELINE_V2_ENDGAME_SOFT_DEFENSE_PRESSURE_SCALE,
        0.75,
        "endgame soft defense pressure should remain stronger while still staying score-based"
    )
    assertEquals(
        tournament.PIPELINE_V2_SOFT_DEFENSE_LETHAL_UNRESOLVED_PENALTY,
        120000,
        "relaxed lethal defense should heavily score unresolved immediate loss"
    )
    assertTrue(
        tournament.PIPELINE_V2_SOFT_DEFENSE_PROOF_GUARD_ENABLED == true,
        "soft DEFEND_NOW pressure should not be reported as solved unless it is reduced"
    )
    assertTrue(
        tournament.PIPELINE_V2_RETURN_FAST_ACCEPTED_ON_FAIL_CLOSED == true,
        "V2 should recover its own best fast accepted candidate on timeout fail-closed"
    )
    assertTrue(
        tournament.PIPELINE_V2_DESTINATION_EXPOSURE_GUARD_ENABLED == true,
        "V2 destination exposure scoring should be enabled through the old compatibility switch"
    )
    assertTrue(
        tournament.PIPELINE_V2_DESTINATION_EXPOSURE_SCORING_ENABLED == true,
        "V2 should score exposed destinations instead of vetoing them"
    )
    assertTrue(
        tournament.PIPELINE_V2_COMMANDANT_PRESSURE_SOFT_GATE == true,
        "V2 should score opened commandant pressure instead of vetoing legal moves"
    )
    assertTrue(
        tournament.PIPELINE_V2_EARLY_MOVE_RISK_ORDERING_ENABLED == true,
        "early V2 second-action ordering should account for reply and suicidal move risk"
    )
    assertEquals(
        tournament.PIPELINE_V2_EARLY_SUICIDAL_MOVE_PENALTY,
        120000,
        "suicidal early moves should be a large score penalty, not a gate rejection"
    )
    assertTrue(
        tournament.PIPELINE_V2_EARLY_FORCED_MOVE_VALUE_ENABLED == true,
        "forced early movements should still be ordered by destination value"
    )
    assertEquals(
        tournament.PIPELINE_V2_EARLY_DESTINATION_DAMAGE_PENALTY,
        22000,
        "early destination damage should be a large score penalty, not a gate rejection"
    )
    assertEquals(
        tournament.PIPELINE_V2_MID_DESTINATION_LETHAL_PENALTY,
        70000,
        "mid destination lethal exposure should be a large score penalty"
    )
    assertEquals(
        tournament.PIPELINE_V2_GATE_EXTRA_MS,
        500,
        "V2 should add extra gate budget after candidate generation"
    )
    assertEquals(
        tournament.PIPELINE_V2_FINALISTS_EXTRA_MS,
        500,
        "V2 should add extra finalist budget after gate acceptance"
    )
    assertTrue(
        tournament.PIPELINE_V2_EARLY_HOLD_NONLETHAL_OCCUPIED_THREAT == true,
        "V2 should let already occupied early cells hold non-lethal threats"
    )
    assertTrue(
        tournament.EARLY_POSITION_TARGET_SPACING_ENABLED == true,
        "early V2 should keep primary targets spaced by default"
    )
    assertEquals(
        tournament.EARLY_POSITION_TARGET_MIN_DISTANCE,
        2,
        "early V2 primary targets should not be adjacent"
    )
    assertTrue(
        tournament.EARLY_POSITION_FRONTIER_ENABLED == true,
        "early V2 should classify frontier/support/rear cells by default"
    )
    assertTrue(
        tournament.EARLY_POSITION_FRONTIER_PRE_TARGET_ENABLED == true,
        "early V2 should demote cells behind the owned frontier before target selection"
    )
    assertEquals(
        tournament.EARLY_POSITION_FRONTIER_FLOOR_MARGIN,
        1,
        "early V2 frontier floor should only demote cells behind the owned line"
    )
    assertEquals(
        tournament.EARLY_POSITION_FRONTIER_LOCAL_LATERAL_MARGIN,
        0.75,
        "early V2 frontier floor should be local by lane instead of global-only"
    )
    assertTrue(
        tournament.EARLY_POSITION_FRONTIER_PROJECTED_ENABLED == true,
        "early V2 should project sparse frontier anchors before target selection"
    )
    assertEquals(
        tournament.EARLY_POSITION_FRONTIER_PROJECTED_TARGET_BONUS,
        80,
        "projected frontier anchors should get a visible but bounded target bonus"
    )
    assertTrue(
        tournament.EARLY_POSITION_HOME_ADJACENT_RESERVE_ENABLED == true,
        "early V2 should keep commandant-adjacent cells as reserve unless DEFEND_NOW is active"
    )
    assertEquals(
        tournament.EARLY_POSITION_HOME_ADJACENT_RESERVE_PENALTY,
        160,
        "early V2 should softly penalize home-adjacent movement/deploy targets"
    )
    assertEquals(
        tournament.EARLY_POSITION_HOME_ADJACENT_OCCUPIED_EXTRA_PENALTY,
        100,
        "early V2 should prefer releasing occupied home-adjacent reserve cells"
    )
    assertEquals(
        tournament.EARLY_POSITION_FRONTIER_SUPPORT_RADIUS,
        2,
        "early V2 support cells should sit near the frontier"
    )
    assertEquals(
        tournament.PIPELINE_V2_EARLY_HOLD_THREAT_COVER_BONUS,
        180,
        "V2 should prioritize covering already-held non-lethal threatened cells"
    )
    assertTrue(tournament.PIPELINE_V2_USE_LEGACY_EARLY_GATE == nil, "V2 should not expose the old early gate")
    assertTrue(
        tournament.PIPELINE_V2_LEGACY_FULL_TURN_FALLBACK_ENABLED == nil,
        "V2 should not expose old full-turn fallback"
    )
    assertTrue(
        tournament.PIPELINE_V2_FULL_TURN_TECHNICAL_SECOND_ENABLED == false,
        "V2 should not invent generic technical second actions during normal play"
    )
    assertEquals(
        tournament.PIPELINE_V2_FULL_TURN_TECHNICAL_SECOND_SCAN_CAP,
        12,
        "V2 technical second completion should remain narrowly capped when explicitly re-enabled"
    )
    assertTrue(
        tournament.PIPELINE_V2_EARLY_GATE_ALLOW_TECHNICAL_SECOND == false,
        "V2 early gate should reject generic technical completion reasons by default"
    )
    assertTrue(
        tournament.PIPELINE_V2_POSITION_PATTERN_PENALTY_ENABLED == true,
        "V2 position scoring should use recent move patterns as a soft anti-oscillation penalty"
    )
    assertEquals(
        tournament.PIPELINE_V2_POSITION_PATTERN_PENALTY_CAP,
        220,
        "V2 position pattern penalty should be capped so it stays a score nudge"
    )
    assertTrue(
        tournament.PIPELINE_V2_CLOUDSTRIKER_MELEE_CONTACT_PENALTY_ENABLED == true,
        "Cloudstriker melee contact should be a reversible scoring penalty by default"
    )
    assertEquals(
        tournament.PIPELINE_V2_CLOUDSTRIKER_MELEE_CONTACT_PENALTY,
        3200,
        "Cloudstriker melee contact should be strongly disincentivized without becoming a veto"
    )
    assertEquals(
        tournament.PIPELINE_V2_EARLY_FORCED_MOVE_OWNED_CELL_CHURN_PENALTY,
        240,
        "forced early movement should softly dislike shuffling into already-owned cells"
    )
    assertTrue(
        tournament.PIPELINE_V2_DEPLOY_FIRST_LEGACY_CONTINUATIONS_ENABLED == nil,
        "V2 should not expose old deploy-first continuations"
    )
    assertTrue(
        tournament.PIPELINE_V2_STRICT_SUPPORT_COVER_ENABLED == true,
        "V2 support-cover cells should require real coverage of an occupied strategic cell"
    )
    assertTrue(
        tournament.PIPELINE_V2_EARLY_STAGING_ENABLED == true,
        "V2 should keep non-cover staging cells distinct from real support cover"
    )
    assertTrue(tournament.PIPELINE_V2_MID_ENABLED == true, "mid V2 should be enabled now that attack candidates are wired")
    assertTrue(
        tournament.PIPELINE_V2_MID_ATTACK_CANDIDATES_ENABLED == true,
        "mid V2 attack candidates should be enabled behind their own switch"
    )
    assertEquals(
        tournament.PIPELINE_V2_MID_GATE_EXTRA_MS,
        500,
        "mid V2 should add its own extra gate budget after candidate generation"
    )
    assertEquals(
        tournament.PIPELINE_V2_MID_ATTACK_EXTRA_MS,
        500,
        "mid V2 attack generation should have its own additive budget"
    )
    assertTrue(
        tournament.PIPELINE_V2_MID_KEEP_LEGAL_DAMAGE_ATTACKS == true,
        "mid V2 should score legal damaging attacks instead of threshold-vetoing them"
    )
    assertEquals(
        tournament.PIPELINE_V2_MID_SECOND_EXTRA_MS,
        500,
        "mid V2 second-action completion should have its own additive budget"
    )
    assertTrue(
        tournament.PIPELINE_V2_MID_SECOND_PREFIX_RECOVERY_ENABLED == true,
        "mid V2 should recover accepted attack prefixes with scored legal second actions"
    )
    assertEquals(
        tournament.PIPELINE_V2_MID_SECOND_PREFIX_RECOVERY_SCAN_CAP,
        6,
        "mid V2 prefix recovery should inspect a bounded legal second-action window"
    )
    assertEquals(
        tournament.PIPELINE_V2_MID_POSITION_SECOND_EXTRA_MS,
        500,
        "mid V2 position second-action completion should have its own additive budget"
    )
    assertEquals(
        tournament.PIPELINE_V2_MID_POSITION_EXTRA_MS,
        750,
        "mid V2 position generation should have enough local budget to complete candidates"
    )
    assertTrue(
        tournament.PIPELINE_V2_MID_RETURN_BEST_ON_GATE_EMPTY == true,
        "mid V2 should recover its best generated candidate when the gate accepts none"
    )
    assertTrue(
        tournament.PIPELINE_V2_ENDGAME_ENABLED == true,
        "endgame V2 should be enabled behind its own switch"
    )
    assertEquals(
        tournament.PIPELINE_V2_ENDGAME_GATE_EXTRA_MS,
        500,
        "endgame V2 should have its own additive gate budget"
    )
    assertTrue(
        tournament.PIPELINE_V2_ENDGAME_FORCE_INTERACTION == true,
        "endgame V2 should prefer accepted interactions over passive closure"
    )
    assertEquals(
        tournament.PIPELINE_V2_ENDGAME_DEPLOY_WITH_SUPPLY_PENALTY,
        3200,
        "endgame deploy should remain available but less attractive near closure"
    )
    assertEquals(
        tournament.PIPELINE_V2_ENDGAME_SUICIDE_KILL_MATERIAL_ADVANTAGE_BONUS,
        3600,
        "endgame material advantage should explicitly reward suicidal kills"
    )
    assertTrue(
        tournament.FULL_TURN_ENUMERATION_TECHNICAL_ONLY == true,
        "full-turn enumeration should remain a technical net only"
    )
    assertTrue(
        tournament.FULL_TURN_GUARANTEED_FALLBACK_ENABLED == false,
        "guaranteed fallback candidates should be opt-in only"
    )
    assertTrue(
        tournament.EARLY_PLAN_REJECT_NEGATIVE_BUILD_POSITION == false,
        "old early formation gate should stay disabled in V2-only runtime"
    )
    assertEquals(tournament.RUNTIME_TAG, "v2_only_early_gate_v2", "runtime tag should be explicit")
end)

runTest("v2_early_destination_exposure_is_scored_not_gated", function()
    ensureHeadlessGlobals()

    local earlyGate = require("ai_tournament.pipeline_v2_early_gate")
    local actionExposureGuard = require("ai_tournament.action_exposure_guard")
    local punishMap = require("ai_tournament.punish_map")
    local originalAnalyzeCell = punishMap.analyzeCell

    local function restore()
        punishMap.analyzeCell = originalAnalyzeCell
    end

    local ok, err = pcall(function()
        punishMap.analyzeCell = function()
            return {
                enemyBestReply = {
                    damage = 1,
                    lethal = false
                }
            }
        end

        local afterOur = {
            units = {
                {name = "Earthstalker", player = 1, row = 4, col = 3, currentHp = 3, startingHp = 3}
            }
        }
        local ai = {
            getUnitAtPosition = function(_, state, row, col)
                for _, item in ipairs(state.units or {}) do
                    if item.row == row and item.col == col then
                        return item
                    end
                end
                return nil
            end
        }
        local candidate = {
            source = "early_position_deploy_first",
            actions = {
                {type = "supply_deploy", unitName = "Wingstalker", target = {row = 6, col = 1}},
                {type = "move", unit = {row = 4, col = 1}, target = {row = 4, col = 3}}
            },
            tacticalTags = {
                earlyPositionReason = "occupy_free_target_then_release_occupant_then_forced_step"
            }
        }
        local ctx = {
            cfg = {
                PIPELINE_V2_DESTINATION_EXPOSURE_GUARD_ENABLED = true,
                PIPELINE_V2_DESTINATION_EXPOSURE_SCORING_ENABLED = true,
                PIPELINE_V2_EARLY_DESTINATION_DAMAGE_PENALTY = 22000,
                PIPELINE_V2_EARLY_DESTINATION_DAMAGE_WEIGHT = 7000
            },
            phase = {early = true},
            earlyPlan = {active = true},
            aiPlayer = 1,
            maxActions = 2,
            stats = {}
        }

        local rejected, reason = earlyGate.rejects(ai, {}, ctx, {}, {
            candidate = candidate,
            afterOur = afterOur
        })

        assertTrue(rejected == false, "early gate should not veto exposed destinations")
        assertEquals(reason, nil, "early gate should leave exposure to scoring")
        local exposure = actionExposureGuard.analyze(ai, afterOur, ctx, candidate, {
            includeDeploy = true,
            phase = "early"
        })
        assertTrue(exposure.penalty > 0, "early exposed destination should receive a score penalty")
        assertEquals(
            candidate.tacticalTags.destinationExposureTarget,
            "4,3",
            "scoring should record exposed destination"
        )
    end)

    restore()
    if not ok then
        error(err, 0)
    end
end)

runTest("v2_early_direct_melee_contact_is_scored_not_gated", function()
    ensureHeadlessGlobals()

    local earlyGate = require("ai_tournament.pipeline_v2_early_gate")
    local actionExposureGuard = require("ai_tournament.action_exposure_guard")

    local afterOur = {
        units = {
            unit("Wingstalker", 1, 4, 3),
            unit("Crusher", 1, 1, 2),
            unit("Wingstalker", 2, 5, 3)
        }
    }
    local ai = {
        getUnitAtPosition = function(_, state, row, col)
            for _, item in ipairs(state.units or {}) do
                if item.row == row and item.col == col then
                    return item
                end
            end
            return nil
        end
    }
    local candidate = {
        source = "early_position_move",
        actions = {
            {type = "move", unit = {row = 4, col = 1}, target = {row = 4, col = 3}},
            {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
        },
        tacticalTags = {
            earlyPositionReason = "move_release_cover_then_forced_step"
        }
    }
    local ctx = {
        cfg = {
            PIPELINE_V2_DESTINATION_EXPOSURE_GUARD_ENABLED = true,
            PIPELINE_V2_DESTINATION_EXPOSURE_SCORING_ENABLED = true,
            PIPELINE_V2_EARLY_DESTINATION_DAMAGE_PENALTY = 22000,
            PIPELINE_V2_EARLY_DESTINATION_DAMAGE_WEIGHT = 7000,
            PIPELINE_V2_EARLY_DIRECT_MELEE_CONTACT_PENALTY = 45000
        },
        phase = {early = true},
        earlyPlan = {active = true},
        aiPlayer = 1,
        maxActions = 2,
        stats = {}
    }

    local rejected, reason = earlyGate.rejects(ai, {}, ctx, {}, {
        candidate = candidate,
        afterOur = afterOur
    })

    assertTrue(rejected == false, "early gate should not veto direct melee contact")
    assertEquals(reason, nil, "early gate should leave direct melee contact to scoring")
    local exposure = actionExposureGuard.analyze(ai, afterOur, ctx, candidate, {
        includeDeploy = true,
        phase = "early"
    })
    assertTrue(exposure.directMeleeContact == true, "direct melee contact should be diagnosed")
    assertTrue(
        exposure.penalty >= 22000 + 7000 + 45000,
        "direct melee contact should add a stronger early score penalty"
    )
    assertTrue(
        candidate.tacticalTags.destinationDirectMeleeContact == true,
        "candidate tags should expose direct melee contact"
    )
end)

runTest("v2_early_destination_exposure_counts_commandant_damage", function()
    ensureHeadlessGlobals()

    local actionExposureGuard = require("ai_tournament.action_exposure_guard")
    local afterOur = {
        units = {
            {name = "Cloudstriker", player = 1, row = 7, col = 7, currentHp = 4, startingHp = 4}
        },
        commandHubs = {
            [1] = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
            [2] = {name = "Commandant", player = 2, row = 7, col = 6, currentHp = 12, startingHp = 12}
        }
    }
    local ai = {
        getUnitAtPosition = function(_, state, row, col)
            for _, item in ipairs(state.units or {}) do
                if item.row == row and item.col == col then
                    return item
                end
            end
            return nil
        end
    }
    local candidate = {
        source = "early_position_move",
        actions = {
            {type = "move", unit = {row = 7, col = 4}, target = {row = 7, col = 7}}
        },
        tacticalTags = {}
    }
    local ctx = {
        cfg = {
            PIPELINE_V2_DESTINATION_EXPOSURE_GUARD_ENABLED = true,
            PIPELINE_V2_DESTINATION_EXPOSURE_SCORING_ENABLED = true,
            PIPELINE_V2_EARLY_DESTINATION_DAMAGE_PENALTY = 22000,
            PIPELINE_V2_EARLY_DESTINATION_DAMAGE_WEIGHT = 7000
        },
        phase = {early = true},
        aiPlayer = 1
    }

    local exposure = actionExposureGuard.analyze(ai, afterOur, ctx, candidate, {
        phase = "early"
    })

    assertTrue(exposure.maxDamage > 0, "adjacent enemy Commandant should count as destination damage")
    assertTrue(exposure.penalty > 0, "Commandant damage should become an early score penalty")
    assertEquals(candidate.tacticalTags.destinationExposureTarget, "7,7", "exposed destination should be recorded")
    assertEquals(
        exposure.analysis.enemyBestReply.attackerName,
        "Commandant",
        "Commandant should be the recorded exposure source"
    )
end)

runTest("mid_gate_keeps_destination_exposure_for_scoring", function()
    ensureHeadlessGlobals()

    local midGate = require("ai_tournament.pipeline_v2_mid_gate")

    local ok, err = pcall(function()
        local afterOur = {
            units = {
                {name = "Earthstalker", player = 1, row = 4, col = 4, currentHp = 3, startingHp = 3}
            }
        }
        local ai = {
            getUnitAtPosition = function(_, state, row, col)
                for _, item in ipairs(state.units or {}) do
                    if item.row == row and item.col == col then
                        return item
                    end
                end
                return nil
            end
        }
        local function makeItem()
            local candidate = {
                source = "mid_v2_position",
                actions = {
                    {type = "move", unit = {row = 2, col = 2}, target = {row = 4, col = 4}}
                },
                tacticalTags = {
                    midPosition = true
                },
                containsAttack = false,
                midPosition = {
                    accepted = true,
                    reason = "mid_position_pressure",
                    lethalExposure = true,
                    destinationExposureLethal = true,
                    destinationExposurePenalty = 70000
                }
            }
            return {
                candidate = candidate,
                afterOur = afterOur
            }
        end
        local ctx = {
            cfg = {
                PIPELINE_V2_DESTINATION_EXPOSURE_GUARD_ENABLED = true
            },
            aiPlayer = 1,
            enemyPlayer = 2
        }

        local accepted, acceptedReason = midGate.check(ai, {}, ctx, {}, makeItem(), {})
        assertTrue(accepted == true, "mid gate should not veto destination exposure")
        assertEquals(acceptedReason, "mid_position_pressure", "mid should keep the position reason")
    end)

    if not ok then
        error(err, 0)
    end
end)

runTest("contract_gate_softens_commandant_pressure_instead_of_veto", function()
    ensureHeadlessGlobals()

    local contractGate = require("ai_tournament.pipeline_v2_contract_gate")
    local beforeState = {id = "before"}
    local afterOur = {id = "after"}
    local candidate = {
        source = "early_position_move",
        actions = {
            {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 3}}
        },
        tacticalTags = {}
    }
    local item = {
        candidate = candidate,
        afterOur = afterOur,
        finalScore = {
            total = 1000,
            survival = 1000,
            breakdown = {}
        }
    }
    local ctx = {
        aiPlayer = 1,
        enemyPlayer = 2,
        cfg = {
            PIPELINE_V2_COMMANDANT_PRESSURE_SOFT_GATE = true,
            OPEN_COMMANDANT_PRESSURE_PENALTY = 100,
            OPEN_COMMANDANT_PRESSURE_DAMAGE_WEIGHT = 10
        },
        stats = {},
        cache = {
            threat = function(_, state)
                if state == beforeState then
                    return {projectedDamage = 0, damagingAttackers = {}}
                end
                return {
                    immediateDanger = true,
                    projectedDamage = 2,
                    damagingAttackers = {{damage = 2}}
                }
            end
        },
        score = {
            finalize = function(score)
                score.total = (tonumber(score.survival) or 0)
            end
        }
    }

    local accepted, reason = contractGate.check({}, beforeState, ctx, {}, item, {})

    assertTrue(accepted == true, "contract gate should not veto legal commandant-pressure moves")
    assertEquals(reason, "accepted", "softened commandant pressure should remain accepted")
    assertTrue(item.finalScore.total < 1000, "soft gate should apply a score penalty")
    assertTrue(
        item.finalScore.breakdown.openedCommandantPressure.softGate == true,
        "score breakdown should record the soft gate"
    )
    assertTrue(
        candidate.tacticalTags.opensCommandantPressureSoftGate == true,
        "candidate should be tagged as softened commandant pressure"
    )
    assertEquals(
        ctx.stats.pipelineV2CommandantPressureSoftened,
        1,
        "softened pressure should be counted for diagnostics"
    )
end)

runTest("mid_gate_softens_commandant_pressure_instead_of_veto", function()
    ensureHeadlessGlobals()

    local midGate = require("ai_tournament.pipeline_v2_mid_gate")
    local beforeState = {id = "before"}
    local afterOur = {id = "after"}
    local candidate = {
        source = "mid_v2_position",
        actions = {
            {type = "move", unit = {row = 4, col = 4}, target = {row = 5, col = 4}}
        },
        containsAttack = false,
        tacticalTags = {
            midPosition = true
        },
        midPosition = {
            accepted = true,
            reason = "mid_position_pressure"
        }
    }
    local item = {
        candidate = candidate,
        afterOur = afterOur,
        finalScore = {
            total = 1000,
            survival = 1000,
            breakdown = {}
        }
    }
    local ctx = {
        aiPlayer = 1,
        enemyPlayer = 2,
        cfg = {
            PIPELINE_V2_COMMANDANT_PRESSURE_SOFT_GATE = true,
            OPEN_COMMANDANT_PRESSURE_PENALTY = 100,
            OPEN_COMMANDANT_PRESSURE_DAMAGE_WEIGHT = 10
        },
        stats = {},
        cache = {
            threat = function(_, state)
                if state == beforeState then
                    return {projectedDamage = 0, damagingAttackers = {}}
                end
                return {
                    immediateDanger = true,
                    projectedDamage = 2,
                    damagingAttackers = {{damage = 2}}
                }
            end
        },
        score = {
            finalize = function(score)
                score.total = (tonumber(score.survival) or 0)
            end
        }
    }

    local accepted, reason = midGate.check({}, beforeState, ctx, {}, item, {})

    assertTrue(accepted == true, "mid gate should not veto legal commandant-pressure moves")
    assertEquals(reason, "mid_position_pressure", "softened mid position should keep its reason")
    assertTrue(item.finalScore.total < 1000, "mid soft gate should apply a score penalty")
    assertTrue(
        item.finalScore.breakdown.openedCommandantPressure.softGate == true,
        "mid score breakdown should record the soft gate"
    )
    assertTrue(
        candidate.tacticalTags.opensCommandantPressureSoftGate == true,
        "mid candidate should be tagged as softened commandant pressure"
    )
    assertEquals(
        ctx.stats.pipelineV2MidCommandantPressureSoftened,
        1,
        "mid softened pressure should be counted for diagnostics"
    )
end)

runTest("v2_adds_gate_budget_after_full_turn_completion", function()
    ensureHeadlessGlobals()

    local pipelineV2 = require("ai_tournament.pipeline_v2")
    local earlyPositionCandidates = require("ai_tournament.early_position_candidates")
    local pipelineV2FullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local contractGate = require("ai_tournament.pipeline_v2_contract_gate")

    local originalDeployFirst = earlyPositionCandidates.generateDeployFirst
    local originalMovePosition = earlyPositionCandidates.generateMovePosition
    local originalComplete = pipelineV2FullTurn.complete
    local originalGateCheck = contractGate.check

    local function restore()
        earlyPositionCandidates.generateDeployFirst = originalDeployFirst
        earlyPositionCandidates.generateMovePosition = originalMovePosition
        pipelineV2FullTurn.complete = originalComplete
        contractGate.check = originalGateCheck
    end

    local ok, err = pcall(function()
        local candidate = {
            source = "early_position_move",
            signature = "complete_candidate",
            actions = {
                {type = "move", fromRow = 1, fromCol = 2, toRow = 1, toCol = 3},
                {type = "move", fromRow = 1, fromCol = 3, toRow = 1, toCol = 4}
            }
        }
        earlyPositionCandidates.generateDeployFirst = function()
            return {candidate}
        end
        earlyPositionCandidates.generateMovePosition = function()
            return {}
        end
        pipelineV2FullTurn.complete = function(_, _, fullTurnCtx, _, candidates)
            assertEquals(fullTurnCtx.hardBudgetMs, 1200, "full-turn completion should keep the normal hard budget")
            return candidates
        end
        contractGate.check = function(_, _, gateCtx)
            assertEquals(gateCtx.hardBudgetMs, 1700, "gate should receive 500ms extra budget")
            return true, "test_gate_accept"
        end

        local ctx = nil
        ctx = {
            cfg = {
                PIPELINE_V2_ENABLED = true,
                PIPELINE_V2_SELECT_ENABLED = true,
                PIPELINE_V2_USE_REPLY = false,
                PIPELINE_V2_REQUIRE_FULL_TURN_CANDIDATES = true,
                PIPELINE_V2_RETURN_FAST_ACCEPTED_ON_FAIL_CLOSED = true,
                PIPELINE_V2_GATE_EXTRA_MS = 500,
                PIPELINE_V2_FULL_TURN_COMPLETION_ENABLED = true,
                PIPELINE_V2_MERGE_POSITIONAL_CANDIDATES = false,
                EARLY_POSITION_MAP_ENABLED = false,
                PIPELINE_V2_MAX_RANKED = 4,
                PIPELINE_V2_MAX_FINALISTS = 2
            },
            phase = {early = true},
            earlyPlan = {active = true},
            stats = {},
            aiPlayer = 1,
            maxActions = 2,
            hardBudgetMs = 1200,
            beginStage = function() end,
            endStage = function() end,
            elapsedMs = function()
                return 1200
            end,
            remainingMs = function()
                return math.max(0, ctx.hardBudgetMs - ctx.elapsedMs())
            end,
            shouldStop = function()
                return ctx.elapsedMs() >= ctx.hardBudgetMs
            end,
            hardStop = function()
                return ctx.elapsedMs() >= ctx.hardBudgetMs
            end,
            tacticalGate = {
                annotateCandidate = function(_, _, annotated)
                    return annotated
                end
            },
            cache = {
                simulate = function(_, _, actions)
                    return {actions = actions}
                end
            },
            evaluator = {
                scoreOwnTurnFast = function()
                    return {total = 10}
                end,
                scoreAfterEnemyReply = function()
                    return {total = 10}
                end
            },
            score = {
                isBetter = function(a, b)
                    local aScore = type(a) == "table" and a.total or a
                    local bScore = type(b) == "table" and b.total or b
                    return (tonumber(aScore) or -math.huge) > (tonumber(bScore) or -math.huge)
                end
            }
        }

        local result = pipelineV2.run({}, {}, ctx, {defenseActive = false}, {})
        assertTrue(result and result.item, "V2 should still return a candidate after extra gate budget")
        assertEquals(
            result.reason,
            "pipeline_v2_best_fast_before_fail_closed",
            "expired finalist budget should recover the gate-accepted fast candidate"
        )
        assertEquals(ctx.stats.pipelineV2GateExtraMs, 500, "stats should record the additive gate budget")
        assertEquals(ctx.stats.pipelineV2GateEvaluated, 1, "gate should evaluate despite original hard timeout")
        assertEquals(ctx.hardBudgetMs, 1200, "gate budget extension should be local to the gate")
    end)

    restore()
    if not ok then
        error(err, 0)
    end
end)

runTest("v2_extra_budget_starts_from_current_stage_elapsed", function()
    ensureHeadlessGlobals()

    local budgetScope = require("ai_tournament.pipeline_v2_budget_scope")
    local elapsed = 1697
    local ctx = nil
    ctx = {
        hardBudgetMs = 1200,
        elapsedMs = function()
            return elapsed
        end,
        remainingMs = function()
            return math.max(0, ctx.hardBudgetMs - elapsed)
        end
    }
    local stats = {}

    local scope = budgetScope.push(ctx, stats, {
        extraMs = 500,
        extraKey = "extra",
        remainingKey = "remaining",
        startKey = "start",
        extendedKey = "extended",
        localWindowKey = "window"
    })

    assertEquals(ctx.hardBudgetMs, 2197, "stage budget should start at current elapsed time")
    assertEquals(stats.remaining, 0, "expired global budget should be recorded before the local window")
    assertEquals(stats.start, 1697, "stage start elapsed should be recorded")
    assertEquals(stats.extended, 2197, "extended deadline should include the local stage window")
    assertEquals(stats.window, 500, "local window should be the requested extra budget")

    scope.pop()
    assertEquals(ctx.hardBudgetMs, 1200, "stage budget should restore the global deadline")
end)

runTest("v2_adds_finalist_budget_after_gate_acceptance", function()
    ensureHeadlessGlobals()

    local pipelineV2 = require("ai_tournament.pipeline_v2")
    local earlyPositionCandidates = require("ai_tournament.early_position_candidates")
    local pipelineV2FullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local contractGate = require("ai_tournament.pipeline_v2_contract_gate")

    local originalDeployFirst = earlyPositionCandidates.generateDeployFirst
    local originalMovePosition = earlyPositionCandidates.generateMovePosition
    local originalComplete = pipelineV2FullTurn.complete
    local originalGateCheck = contractGate.check

    local function restore()
        earlyPositionCandidates.generateDeployFirst = originalDeployFirst
        earlyPositionCandidates.generateMovePosition = originalMovePosition
        pipelineV2FullTurn.complete = originalComplete
        contractGate.check = originalGateCheck
    end

    local ok, err = pcall(function()
        local candidate = {
            source = "early_position_move",
            signature = "finalist_candidate",
            actions = {
                {type = "move", fromRow = 1, fromCol = 2, toRow = 1, toCol = 3},
                {type = "move", fromRow = 1, fromCol = 3, toRow = 1, toCol = 4}
            }
        }
        earlyPositionCandidates.generateDeployFirst = function()
            return {candidate}
        end
        earlyPositionCandidates.generateMovePosition = function()
            return {}
        end
        pipelineV2FullTurn.complete = function(_, _, _, _, candidates)
            return candidates
        end
        contractGate.check = function()
            return true, "test_gate_accept"
        end

        local elapsed = 900
        local ctx = nil
        ctx = {
            cfg = {
                PIPELINE_V2_ENABLED = true,
                PIPELINE_V2_SELECT_ENABLED = true,
                PIPELINE_V2_USE_REPLY = false,
                PIPELINE_V2_REQUIRE_FULL_TURN_CANDIDATES = true,
                PIPELINE_V2_RETURN_FAST_ACCEPTED_ON_FAIL_CLOSED = true,
                PIPELINE_V2_GATE_EXTRA_MS = 0,
                PIPELINE_V2_FINALISTS_EXTRA_MS = 500,
                PIPELINE_V2_FULL_TURN_COMPLETION_ENABLED = false,
                PIPELINE_V2_MERGE_POSITIONAL_CANDIDATES = false,
                EARLY_POSITION_MAP_ENABLED = false,
                PIPELINE_V2_MAX_RANKED = 4,
                PIPELINE_V2_MAX_FINALISTS = 2
            },
            phase = {early = true},
            earlyPlan = {active = true},
            stats = {},
            aiPlayer = 1,
            maxActions = 2,
            hardBudgetMs = 1000,
            beginStage = function() end,
            endStage = function(name)
                if name == "pipeline_v2_gate" then
                    elapsed = 1000
                end
            end,
            elapsedMs = function()
                return elapsed
            end,
            remainingMs = function()
                return math.max(0, ctx.hardBudgetMs - elapsed)
            end,
            shouldStop = function()
                return elapsed >= ctx.hardBudgetMs
            end,
            hardStop = function()
                return elapsed >= ctx.hardBudgetMs
            end,
            tacticalGate = {
                annotateCandidate = function(_, _, annotated)
                    return annotated
                end
            },
            cache = {
                simulate = function(_, _, actions)
                    return {actions = actions}
                end
            },
            evaluator = {
                scoreOwnTurnFast = function()
                    return {total = 10}
                end,
                scoreAfterEnemyReply = function(_, _, _, _, finalistCandidate)
                    assertEquals(ctx.hardBudgetMs, 1500, "finalists should receive 500ms extra budget")
                    return {total = finalistCandidate.signature == "finalist_candidate" and 20 or 0}
                end
            },
            score = {
                isBetter = function(a, b)
                    local aScore = type(a) == "table" and a.total or a
                    local bScore = type(b) == "table" and b.total or b
                    return (tonumber(aScore) or -math.huge) > (tonumber(bScore) or -math.huge)
                end
            }
        }

        local result = pipelineV2.run({}, {}, ctx, {defenseActive = false}, {})
        assertTrue(result and result.item, "V2 should select a finalist using its extra budget")
        assertEquals(result.reason, "pipeline_v2_selected", "extra finalist budget should avoid best-fast recovery")
        assertEquals(result.item.candidate.signature, "finalist_candidate", "selected finalist should be returned")
        assertEquals(ctx.stats.pipelineV2FinalistsExtraMs, 500, "stats should record finalist additive budget")
        assertEquals(ctx.stats.pipelineV2RemainingBeforeFinalistsMs, 0, "stats should record exhausted normal budget")
        assertEquals(ctx.stats.pipelineV2FinalistsEvaluated, 1, "finalist should be evaluated after budget extension")
        assertEquals(ctx.hardBudgetMs, 1000, "finalist budget extension should be local to finalists")
    end)

    restore()
    if not ok then
        error(err, 0)
    end
end)

runTest("mid_v2_adds_gate_budget_after_candidate_generation", function()
    ensureHeadlessGlobals()

    local pipelineV2Mid = require("ai_tournament.pipeline_v2_mid")
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonality = require("ai_tournament.mid_personality")
    local midAttackCandidates = require("ai_tournament.mid_attack_candidates")
    local midPositionCandidates = require("ai_tournament.mid_position_candidates")
    local midGate = require("ai_tournament.pipeline_v2_mid_gate")

    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonality.interpretMap
    local originalAttackGenerate = midAttackCandidates.generate
    local originalPositionGenerate = midPositionCandidates.generate
    local originalGateCheck = midGate.check

    local function restore()
        midPositionMap.build = originalBuild
        midPersonality.interpretMap = originalInterpret
        midAttackCandidates.generate = originalAttackGenerate
        midPositionCandidates.generate = originalPositionGenerate
        midGate.check = originalGateCheck
    end

    local ok, err = pcall(function()
        local candidate = {
            source = "mid_v2_position",
            signature = "mid_complete_candidate",
            actions = {
                {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}},
                {type = "move", unit = {row = 3, col = 2}, target = {row = 4, col = 2}}
            },
            tacticalTags = {midV2 = true, midPosition = true},
            containsAttack = false,
            completeTurn = true,
            cheapScore = 100,
            midPosition = {
                accepted = true,
                reason = "mid_position_pressure",
                score = 100,
                targetValue = 100,
                pressureGain = 100,
                exposureDamage = 0
            },
            _midAfterState = {units = {}, commandHubs = {}}
        }

        midPositionMap.build = function()
            return {byKey = {}, cells = {}}
        end
        midPersonality.interpretMap = function()
            return {profile = {name = "test", thresholds = {}}, byKey = {}}
        end
        midAttackCandidates.generate = function()
            return {}
        end
        midPositionCandidates.generate = function()
            return {candidate}
        end
        midGate.check = function(_, _, gateCtx)
            assertEquals(gateCtx.hardBudgetMs, 1700, "mid gate should receive 500ms extra budget")
            return true, "mid_gate_position_accepted"
        end

        local ctx = nil
        ctx = {
            cfg = {
                PIPELINE_V2_MID_ENABLED = true,
                PIPELINE_V2_MID_GATE_EXTRA_MS = 500,
                PIPELINE_V2_MID_MAX_RANKED = 4,
                PIPELINE_V2_MID_MAX_FINALISTS = 2
            },
            phase = {name = "mid", mid = true, early = false},
            stats = {},
            aiPlayer = 1,
            enemyPlayer = 2,
            maxActions = 2,
            hardBudgetMs = 1200,
            beginStage = function() end,
            endStage = function() end,
            elapsedMs = function()
                return 1200
            end,
            remainingMs = function()
                return math.max(0, ctx.hardBudgetMs - ctx.elapsedMs())
            end,
            shouldStop = function()
                return ctx.elapsedMs() >= ctx.hardBudgetMs
            end,
            cache = {
                simulate = function(_, _, actions)
                    return {actions = actions}
                end
            },
            score = {
                isBetter = function(a, b)
                    local aScore = type(a) == "table" and a.total or a
                    local bScore = type(b) == "table" and b.total or b
                    return (tonumber(aScore) or -math.huge) > (tonumber(bScore) or -math.huge)
                end
            }
        }

        local result = pipelineV2Mid.run({}, {}, ctx, {defenseActive = false}, {})
        assertTrue(result and result.item, "mid V2 should select after extra gate budget")
        assertEquals(ctx.stats.pipelineV2MidGateExtraMs, 500, "stats should record mid gate extra budget")
        assertEquals(ctx.stats.pipelineV2MidGateEvaluated, 1, "mid gate should evaluate despite original hard timeout")
        assertEquals(ctx.stats.pipelineV2MidAccepted, 1, "mid gate should accept the candidate")
        assertEquals(ctx.hardBudgetMs, 1200, "mid gate budget extension should be local to the gate")
    end)

    restore()
    if not ok then
        error(err, 0)
    end
end)

runTest("mid_v2_recovers_best_candidate_when_gate_accepts_none", function()
    ensureHeadlessGlobals()

    local pipelineV2Mid = require("ai_tournament.pipeline_v2_mid")
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonality = require("ai_tournament.mid_personality")
    local midAttackCandidates = require("ai_tournament.mid_attack_candidates")
    local midPositionCandidates = require("ai_tournament.mid_position_candidates")
    local midGate = require("ai_tournament.pipeline_v2_mid_gate")

    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonality.interpretMap
    local originalAttackGenerate = midAttackCandidates.generate
    local originalPositionGenerate = midPositionCandidates.generate
    local originalGateCheck = midGate.check

    local function restore()
        midPositionMap.build = originalBuild
        midPersonality.interpretMap = originalInterpret
        midAttackCandidates.generate = originalAttackGenerate
        midPositionCandidates.generate = originalPositionGenerate
        midGate.check = originalGateCheck
    end

    local function candidate(signature, score)
        return {
            source = "mid_v2_position",
            signature = signature,
            actions = {
                {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}},
                {type = "move", unit = {row = 3, col = 2}, target = {row = 4, col = 2}}
            },
            tacticalTags = {midV2 = true, midPosition = true},
            containsAttack = false,
            completeTurn = true,
            cheapScore = score,
            midPosition = {
                accepted = true,
                reason = "mid_position_pressure",
                score = score,
                targetValue = score,
                pressureGain = score,
                exposureDamage = 0
            },
            _midAfterState = {units = {}, commandHubs = {}}
        }
    end

    local ok, err = pcall(function()
        midPositionMap.build = function()
            return {byKey = {}, cells = {}}
        end
        midPersonality.interpretMap = function()
            return {profile = {name = "test", thresholds = {}}, byKey = {}}
        end
        midAttackCandidates.generate = function()
            return {}
        end
        midPositionCandidates.generate = function()
            return {
                candidate("low_mid", 50),
                candidate("high_mid", 400)
            }
        end
        midGate.check = function()
            return false, "test_mid_gate_reject"
        end

        local ctx = {
            cfg = {
                PIPELINE_V2_MID_ENABLED = true,
                PIPELINE_V2_MID_GATE_EXTRA_MS = 500,
                PIPELINE_V2_MID_RETURN_BEST_ON_GATE_EMPTY = true,
                PIPELINE_V2_MID_MAX_RANKED = 4,
                PIPELINE_V2_MID_MAX_FINALISTS = 2
            },
            phase = {name = "mid", mid = true, early = false},
            stats = {},
            aiPlayer = 1,
            enemyPlayer = 2,
            maxActions = 2,
            hardBudgetMs = 1200,
            beginStage = function() end,
            endStage = function() end,
            elapsedMs = function()
                return 1200
            end,
            remainingMs = function()
                return 0
            end,
            shouldStop = function()
                return false
            end,
            cache = {
                simulate = function(_, _, actions)
                    return {actions = actions}
                end
            },
            score = {
                isBetter = function(a, b)
                    local aScore = type(a) == "table" and a.total or a
                    local bScore = type(b) == "table" and b.total or b
                    return (tonumber(aScore) or -math.huge) > (tonumber(bScore) or -math.huge)
                end
            }
        }

        local result = pipelineV2Mid.run({}, {}, ctx, {defenseActive = false}, {})

        assertTrue(result and result.item, "mid should recover a generated candidate instead of technical fallback")
        assertEquals(
            result.reason,
            "pipeline_v2_mid_best_candidate_before_fail_closed",
            "recovery reason should be explicit"
        )
        assertEquals(result.item.candidate.signature, "high_mid", "mid should recover the best generated candidate")
        assertEquals(ctx.stats.pipelineV2MidAccepted, 0, "gate should still record no accepted candidates")
        assertEquals(ctx.stats.pipelineV2MidPrepared, 2, "prepared candidate count should be logged")
        assertTrue(ctx.stats.pipelineV2MidRecoveredBestCandidate == true, "best recovery should be logged")
        assertEquals(
            ctx.stats.pipelineV2MidRecoveredGateRejectReason,
            "test_mid_gate_reject",
            "gate reject reason should remain visible"
        )
        assertEquals(
            ctx.stats.pipelineV2MidSelectedAcceptReason,
            "mid_best_candidate_after_gate_empty",
            "selected reason should show best recovery"
        )
    end)

    restore()
    if not ok then
        error(err, 0)
    end
end)

runTest("mid_v2_recovers_legal_floor_when_gate_accepts_none_after_floor", function()
    ensureHeadlessGlobals()

    local pipelineV2Mid = require("ai_tournament.pipeline_v2_mid")
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonality = require("ai_tournament.mid_personality")
    local midAttackCandidates = require("ai_tournament.mid_attack_candidates")
    local midPositionCandidates = require("ai_tournament.mid_position_candidates")
    local midDeployCandidates = require("ai_tournament.mid_deploy_candidates")
    local midGate = require("ai_tournament.pipeline_v2_mid_gate")
    local turnEnumerator = require("ai_tournament.turn_enumerator")

    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonality.interpretMap
    local originalAttackGenerate = midAttackCandidates.generate
    local originalPositionGenerate = midPositionCandidates.generate
    local originalDeployGenerate = midDeployCandidates.generate
    local originalGateCheck = midGate.check
    local originalFullTurn = turnEnumerator.generateFullTurnCandidates

    local function restore()
        midPositionMap.build = originalBuild
        midPersonality.interpretMap = originalInterpret
        midAttackCandidates.generate = originalAttackGenerate
        midPositionCandidates.generate = originalPositionGenerate
        midDeployCandidates.generate = originalDeployGenerate
        midGate.check = originalGateCheck
        turnEnumerator.generateFullTurnCandidates = originalFullTurn
    end

    local ok, err = pcall(function()
        midPositionMap.build = function()
            return {byKey = {}, cells = {}}
        end
        midPersonality.interpretMap = function()
            return {profile = {name = "test", thresholds = {}}, byKey = {}}
        end
        midAttackCandidates.generate = function()
            return {}
        end
        midPositionCandidates.generate = function()
            return {
                {
                    source = "mid_v2_attack",
                    signature = "bad_unprepared_attack",
                    actions = {
                        {type = "attack", unit = {row = 2, col = 2}, target = {row = 2, col = 3}},
                        {type = "move", unit = {row = 1, col = 1}, target = {row = 1, col = 2}}
                    },
                    tacticalTags = {midV2 = true},
                    containsAttack = true,
                    completeTurn = true,
                    cheapScore = 900
                }
            }
        end
        midDeployCandidates.generate = function()
            return {}
        end
        turnEnumerator.generateFullTurnCandidates = function()
            return {
                {
                    source = "generated_floor",
                    signature = "floor_rejected_attack_pair",
                    actions = {
                        {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}},
                        {type = "attack", unit = {row = 3, col = 2}, target = {row = 3, col = 3}}
                    },
                    containsAttack = true,
                    containsDeploy = false,
                    completeTurn = true,
                    cheapScore = 120
                }
            }
        end
        midGate.check = function()
            return false, "test_floor_gate_reject"
        end

        local ctx = {
            cfg = {
                PIPELINE_V2_MID_ENABLED = true,
                PIPELINE_V2_MID_GATE_EXTRA_MS = 500,
                PIPELINE_V2_MID_RETURN_BEST_ON_GATE_EMPTY = true,
                PIPELINE_V2_MID_LEGAL_FLOOR_ENABLED = true,
                PIPELINE_V2_MID_LEGAL_FLOOR_EXTRA_MS = 0,
                PIPELINE_V2_MID_MAX_RANKED = 4,
                PIPELINE_V2_MID_MAX_FINALISTS = 2
            },
            phase = {name = "mid", mid = true, early = false},
            stats = {},
            aiPlayer = 1,
            enemyPlayer = 2,
            maxActions = 2,
            hardBudgetMs = 1200,
            sanitizeRejectZeroDamage = nil,
            beginStage = function() end,
            endStage = function() end,
            elapsedMs = function()
                return 0
            end,
            remainingMs = function()
                return 1200
            end,
            shouldStop = function()
                return false
            end,
            cache = {
                simulate = function(_, _, actions)
                    return {actions = actions, units = {}, commandHubs = {}}
                end
            },
            score = {
                isBetter = function(a, b)
                    local aScore = type(a) == "table" and a.total or a
                    local bScore = type(b) == "table" and b.total or b
                    return (tonumber(aScore) or -math.huge) > (tonumber(bScore) or -math.huge)
                end
            }
        }

        local ai = {
            sanitizeActionSequenceForState = function(_, _, actions, opts)
                ctx.sanitizeRejectZeroDamage = opts and opts.rejectZeroDamageFactionAttacks
                return actions, {replacements = 0, reasonCounts = {}}
            end
        }
        local result = pipelineV2Mid.run(ai, {}, ctx, {defenseActive = false}, {})

        assertTrue(result and result.item, "mid should recover legal floor instead of fail-closed")
        assertEquals(result.reason, "pipeline_v2_mid_best_candidate_before_fail_closed")
        assertEquals(result.item.candidate.source, "mid_v2_legal_floor", "recovered item should be the generated legal floor")
        assertTrue(
            result.item.candidate.containsAttack ~= true,
            "rejected legal floor attack should be scored as positional floor"
        )
        assertTrue(
            result.item.candidate.tacticalTags.midLegalFloorRejectedAttackKept == true,
            "rejected legal floor attack should stay available as penalized floor"
        )
        assertEquals(
            ctx.sanitizeRejectZeroDamage,
            false,
            "kept rejected floor attacks should not be sanitized away by zero-damage guard"
        )
        assertTrue(ctx.stats.pipelineV2MidRecoveredBestCandidate == true, "recovery should be logged")
        assertTrue(ctx.stats.pipelineV2MidRecoveredAfterLegalFloor == true, "post-floor recovery should be explicit")
        assertEquals(ctx.stats.pipelineV2MidRecoveredGateRejectReason, "test_floor_gate_reject")
    end)

    restore()
    if not ok then
        error(err, 0)
    end
end)

runTest("mid_v2_keeps_lethal_destination_candidate_with_penalty", function()
    ensureHeadlessGlobals()

    local pipelineV2Mid = require("ai_tournament.pipeline_v2_mid")
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonality = require("ai_tournament.mid_personality")
    local midAttackCandidates = require("ai_tournament.mid_attack_candidates")
    local midPositionCandidates = require("ai_tournament.mid_position_candidates")
    local punishMap = require("ai_tournament.punish_map")

    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonality.interpretMap
    local originalAttackGenerate = midAttackCandidates.generate
    local originalPositionGenerate = midPositionCandidates.generate
    local originalAnalyzeCell = punishMap.analyzeCell

    local function restore()
        midPositionMap.build = originalBuild
        midPersonality.interpretMap = originalInterpret
        midAttackCandidates.generate = originalAttackGenerate
        midPositionCandidates.generate = originalPositionGenerate
        punishMap.analyzeCell = originalAnalyzeCell
    end

    local ok, err = pcall(function()
        local candidate = {
            source = "mid_v2_position",
            signature = "lethal_mid_position",
            actions = {
                {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}},
                {type = "move", unit = {row = 3, col = 2}, target = {row = 4, col = 2}}
            },
            tacticalTags = {midV2 = true, midPosition = true},
            containsAttack = false,
            completeTurn = true,
            cheapScore = 500,
            midPosition = {
                accepted = true,
                reason = "mid_position_pressure",
                score = 500,
                targetValue = 500,
                pressureGain = 500,
                exposureDamage = 0
            },
            _midAfterState = {
                units = {
                    {name = "Earthstalker", player = 1, row = 4, col = 2, currentHp = 3, startingHp = 3}
                },
                commandHubs = {}
            }
        }

        midPositionMap.build = function()
            return {byKey = {}, cells = {}}
        end
        midPersonality.interpretMap = function()
            return {profile = {name = "test", thresholds = {}}, byKey = {}}
        end
        midAttackCandidates.generate = function()
            return {}
        end
        midPositionCandidates.generate = function()
            return {candidate}
        end
        punishMap.analyzeCell = function()
            return {
                enemyBestReply = {
                    damage = 3,
                    lethal = true
                }
            }
        end

        local ai = {
            getUnitAtPosition = function(_, state, row, col)
                for _, item in ipairs(state.units or {}) do
                    if item.row == row and item.col == col then
                        return item
                    end
                end
                return nil
            end
        }
        local ctx = {
            cfg = {
                PIPELINE_V2_MID_ENABLED = true,
                PIPELINE_V2_MID_GATE_EXTRA_MS = 500,
                PIPELINE_V2_MID_RETURN_BEST_ON_GATE_EMPTY = true,
                PIPELINE_V2_DESTINATION_EXPOSURE_GUARD_ENABLED = true,
                PIPELINE_V2_MID_MAX_RANKED = 4,
                PIPELINE_V2_MID_MAX_FINALISTS = 2
            },
            phase = {name = "mid", mid = true, early = false},
            stats = {},
            aiPlayer = 1,
            enemyPlayer = 2,
            maxActions = 2,
            hardBudgetMs = 1200,
            beginStage = function() end,
            endStage = function() end,
            remainingMs = function()
                return 1200
            end,
            shouldStop = function()
                return false
            end,
            cache = {
                simulate = function(_, _, _, _, _)
                    return candidate._midAfterState
                end
            },
            score = {
                isBetter = function(a, b)
                    local aScore = type(a) == "table" and a.total or a
                    local bScore = type(b) == "table" and b.total or b
                    return (tonumber(aScore) or -math.huge) > (tonumber(bScore) or -math.huge)
                end
            }
        }

        local result = pipelineV2Mid.run(ai, {}, ctx, {defenseActive = false}, {})

        assertTrue(result and result.item, "mid should keep the only legal destination candidate")
        assertEquals(result.reason, "pipeline_v2_mid_selected", "candidate should be selected by mid V2, not fallback")
        assertEquals(ctx.stats.pipelineV2MidAccepted, 1, "gate should not veto lethal destination exposure")
        assertTrue(
            result.item.candidate.tacticalTags.destinationExposureLethal == true,
            "candidate should keep lethal destination exposure diagnostics"
        )
        assertTrue(
            (result.item.finalScore.survival or 0) < 0,
            "lethal destination exposure should be paid through score"
        )
    end)

    restore()
    if not ok then
        error(err, 0)
    end
end)

runTest("mid_v2_no_candidates_fail_closed_without_legacy_fallthrough", function()
    ensureHeadlessGlobals()

    local pipelineV2Mid = require("ai_tournament.pipeline_v2_mid")
    local ai = mkAI(1)
    local state = baseState({turnNumber = 11})
    local ctx = {
        cfg = {
            PIPELINE_V2_MID_ENABLED = false
        },
        stats = {},
        phase = {
            name = "mid",
            mid = true,
            early = false
        },
        beginStage = function() end,
        endStage = function() end
    }

    local disabled = pipelineV2Mid.run(ai, state, ctx, {}, {})
    assertTrue(disabled and disabled.attempted == false, "disabled mid V2 should not attempt selection")
    assertEquals(ctx.stats.pipelineV2MidSkippedReason, "disabled", "disabled mid V2 should be explicit")

    ctx.cfg.PIPELINE_V2_MID_ENABLED = true
    ctx.stats = {}
    local enabled = pipelineV2Mid.run(ai, state, ctx, {}, {})
    assertTrue(enabled and enabled.attempted == true, "enabled mid V2 skeleton should be observable")
    assertEquals(enabled.reason, "no_mid_candidates", "empty mid V2 should fail closed")
    assertTrue(enabled.failClosed == true, "empty mid V2 should report fail-closed")
    assertTrue(ctx.stats.pipelineV2MidFailClosed == true, "empty mid V2 should mark fail-closed stats")
    assertTrue(ctx.stats.pipelineV2MidFellThroughToTournament ~= true, "mid V2 must not fall through to old tournament")
    assertEquals(ctx.stats.pipelineV2MidCandidates, 0, "empty mid V2 should not emit candidates")
    assertTrue(ctx.stats.midPositionMapEnabled == true, "enabled mid V2 should build the neutral mid map")
    assertTrue((ctx.stats.midPositionMapCellCount or 0) > 0, "mid map should expose scored cells before fail-closed")
    assertTrue(ctx.stats.midPersonalityName ~= nil, "enabled mid V2 should interpret the map through personality")
    assertTrue(#(ctx.stats.midPersonalityTop or {}) > 0, "personality interpretation should expose ranked cells")
end)

runTest("brain_mid_v2_fail_closed_goes_to_technical_net_not_legacy", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.TURN = 11
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local midAttackCandidates = require("ai_tournament.mid_attack_candidates")
    local midPositionCandidates = require("ai_tournament.mid_position_candidates")
    local midDeployCandidates = require("ai_tournament.mid_deploy_candidates")
    local originalAttackGenerate = midAttackCandidates.generate
    local originalPositionGenerate = midPositionCandidates.generate
    local originalDeployGenerate = midDeployCandidates.generate

    local function restore()
        midAttackCandidates.generate = originalAttackGenerate
        midPositionCandidates.generate = originalPositionGenerate
        midDeployCandidates.generate = originalDeployGenerate
    end

    local ok, sequence, meta = pcall(function()
        midAttackCandidates.generate = function()
            return {}
        end
        midPositionCandidates.generate = function()
            return {}
        end
        midDeployCandidates.generate = function()
            return {}
        end

        local AI = require("ai")
        local ai = AI.new({factionId = 1})
        ai.grid = {
            getUnitAt = function()
                return nil
            end
        }
        return require("ai_tournament.brain").chooseTurn(ai, baseState({
            actingPlayer = 1,
            turnNumber = 11,
            units = {},
            neutralBuildings = {}
        }), {
            maxActions = 2,
            decisionStartTime = love.timer.getTime(),
            softBudgetMs = 900,
            hardBudgetMs = 1200
        })
    end)

    restore()
    if not ok then
        error(sequence, 0)
    end

    local stats = meta and meta.stats or {}
    assertEquals(sequence, nil, "fail-closed mid should not synthesize a legacy sequence")
    assertEquals(meta.contract, "TECHNICAL_FALLBACK", "mid fail-closed should use the technical net")
    assertEquals(stats.coreExit, "pipeline_v2_mid_no_selection", "core exit should identify mid V2 fail-closed")
    assertEquals(stats.fallbackSource, "technical_fallback", "fallback source should be technical only")
    assertTrue(stats.pipelineV2MidFailClosed == true, "mid fail-closed should be recorded")
    assertTrue(stats.pipelineV2MidFellThroughToTournament ~= true, "brain must not fall through to legacy tournament")
end)

runTest("v2_timeout_recovers_best_fast_candidate_before_technical_fallback", function()
    ensureHeadlessGlobals()

    local pipelineV2 = require("ai_tournament.pipeline_v2")
    local earlyPositionCandidates = require("ai_tournament.early_position_candidates")
    local pipelineV2FullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local contractGate = require("ai_tournament.pipeline_v2_contract_gate")

    local originalDeployFirst = earlyPositionCandidates.generateDeployFirst
    local originalMovePosition = earlyPositionCandidates.generateMovePosition
    local originalComplete = pipelineV2FullTurn.complete
    local originalGateCheck = contractGate.check

    local function restore()
        earlyPositionCandidates.generateDeployFirst = originalDeployFirst
        earlyPositionCandidates.generateMovePosition = originalMovePosition
        pipelineV2FullTurn.complete = originalComplete
        contractGate.check = originalGateCheck
    end

    local ok, err = pcall(function()
        earlyPositionCandidates.generateDeployFirst = function()
            return {
                {
                    source = "early_position_deploy_first",
                    signature = "low_fast",
                    testScore = 10,
                    actions = {
                        {type = "supply_deploy", unitName = "Crusher", row = 1, col = 2},
                        {type = "move", fromRow = 1, fromCol = 3, toRow = 1, toCol = 4}
                    }
                },
                {
                    source = "early_position_deploy_first",
                    signature = "high_fast",
                    testScore = 50,
                    actions = {
                        {type = "supply_deploy", unitName = "Bastion", row = 1, col = 2},
                        {type = "move", fromRow = 1, fromCol = 3, toRow = 1, toCol = 5}
                    }
                }
            }
        end
        earlyPositionCandidates.generateMovePosition = function()
            return {}
        end
        pipelineV2FullTurn.complete = function(_, _, _, _, candidates)
            return candidates
        end
        contractGate.check = function()
            return true, "test_fast_accepted"
        end

        local inFinalistStage = false
        local ctx = {
            cfg = {
                PIPELINE_V2_ENABLED = true,
                PIPELINE_V2_SELECT_ENABLED = true,
                PIPELINE_V2_RETURN_FAST_ACCEPTED_ON_FAIL_CLOSED = true,
                PIPELINE_V2_REQUIRE_FULL_TURN_CANDIDATES = true,
                PIPELINE_V2_FULL_TURN_COMPLETION_ENABLED = false,
                PIPELINE_V2_MERGE_POSITIONAL_CANDIDATES = false,
                EARLY_POSITION_MAP_ENABLED = false,
                PIPELINE_V2_MAX_RANKED = 4,
                PIPELINE_V2_MAX_FINALISTS = 2
            },
            phase = {early = true},
            earlyPlan = {active = true},
            stats = {},
            aiPlayer = 1,
            maxActions = 2,
            beginStage = function(name)
                if name == "pipeline_v2_finalists" then
                    inFinalistStage = true
                end
            end,
            endStage = function() end,
            shouldStop = function()
                return false
            end,
            hardStop = function()
                return inFinalistStage
            end,
            tacticalGate = {
                annotateCandidate = function(_, _, candidate)
                    return candidate
                end
            },
            cache = {
                simulate = function(_, _, actions)
                    return {actions = actions}
                end
            },
            evaluator = {
                scoreOwnTurnFast = function(_, _, _, candidate)
                    return {total = candidate.testScore or 0}
                end
            },
            score = {
                isBetter = function(a, b)
                    local aScore = type(a) == "table" and a.total or a
                    local bScore = type(b) == "table" and b.total or b
                    return (tonumber(aScore) or -math.huge) > (tonumber(bScore) or -math.huge)
                end
            }
        }

        local result = pipelineV2.run({}, {}, ctx, {defenseActive = false}, {})
        assertTrue(result and result.item, "V2 should recover a fast accepted candidate")
        assertEquals(result.reason, "pipeline_v2_best_fast_before_fail_closed", "recovery reason should be explicit")
        assertEquals(result.fallbackSource, "pipeline_v2_best_fast", "recovery should not be technical fallback")
        assertEquals(result.item.candidate.signature, "high_fast", "V2 should recover the best fast accepted candidate")
        assertTrue(ctx.stats.timeout == true, "test should exercise timeout recovery")
        assertTrue(ctx.stats.pipelineV2RecoveredFastAccepted == true, "stats should record fast recovery")
        assertEquals(
            ctx.stats.pipelineV2BestFastAcceptedSignature,
            "high_fast",
            "stats should remember the best fast accepted signature"
        )
    end)

    restore()
    if not ok then
        error(err, 0)
    end
end)

runTest("v2_early_selects_position_candidate_without_full_turn_pool", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 2
    local ai = mkAI(2)
    local sequence, meta = choose(ai, earlyBuildPositionState())
    local stats = meta.stats or {}

    assertEquals(meta.reason, "pipeline_v2_selected", "early BUILD_POSITION should be selected by V2")
    assertEquals(stats.coreExit, "pipeline_v2_selected", "core exit should report V2 selection")
    assertEquals(meta.contract, "BUILD_POSITION", "V2 early path should own BUILD_POSITION")
    assertTrue(stats.pipelineV2Enabled == true, "pipeline V2 should run")
    assertTrue(stats.pipelineV2EarlyGateEnabled == true, "pipeline V2 should use its own early gate")
    assertEquals(stats.pipelineV2EarlyGatePath, "v2", "pipeline V2 should use its own early gate")
    assertTrue((tonumber(stats.pipelineV2EarlyGateAccepted) or 0) > 0, "V2 early gate should accept valid V2 candidates")
    assertNoLegacyEarlyGateRejection(stats)
    assertTrue((tonumber(stats.pipelineV2Candidates) or 0) > 0, "V2 should generate candidates")
    assertTrue(stats.pipelineV2FullTurnEnabled == true, "V2 full-turn completion should run")
    assertEquals(
        tonumber(stats.pipelineV2Candidates) or 0,
        tonumber(stats.pipelineV2FullTurnOutputCandidates) or 0,
        "V2 should select from full-turn-completed candidates"
    )
    assertEquals(
        tonumber(stats.pipelineV2FullTurnSingleActionOutput) or 0,
        0,
        "V2 full-turn completion should not leak one-action candidates"
    )
    assertTrue((tonumber(stats.pipelineV2Accepted) or 0) > 0, "V2 contract gate should accept candidates")
    assertTrue(isEarlyPositionSource(stats.selectedCandidateSource), "selected source should be an early-position candidate")
    assertTrue(#sequence == 2, "V2 should return a complete two-action candidate")
    assertTrue((tonumber(stats.sanitizerReplacements) or 0) == 0, "V2 selection should not depend on sanitizer repair")
    assertNoNormalFullTurnCompetition(stats)
end)

runTest("v2_generates_own_deploy_and_second_action_candidates", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 2
    local ai = mkAI(2)
    local _, meta = choose(ai, earlyBuildPositionState())
    local stats = meta.stats or {}

    assertTrue((tonumber(stats.pipelineV2DeployFirstCandidates) or 0) > 0, "deploy-first generator should produce candidates")
    assertTrue((tonumber(stats.pipelineV2DeployFirstContinuationCandidates) or 0) > 0, "V2 should form two-action continuations")
    assertTrue((tonumber(stats.pipelineV2DeployFirstEarlySecondScanned) or 0) > 0, "V2 should scan its early second action")
    assertTrue(stats.pipelineV2EarlyGateEnabled == true, "V2 early gate diagnostics should be present")
    assertNoLegacyEarlyGateRejection(stats)
    assertTrue((tonumber(stats.pipelineV2FullTurnInputCandidates) or 0) > 0, "V2 full-turn completion should receive generated candidates")
    assertTrue((tonumber(stats.pipelineV2FullTurnCompleted) or 0) > 0, "V2 should complete single-action candidates natively")
    assertEquals(
        tonumber(stats.pipelineV2FullTurnSingleActionOutput) or 0,
        0,
        "completed V2 pool should stay two-action only"
    )
    assertTrue(next(stats.pipelineV2DeployFirstReasonCounts or {}) ~= nil, "deploy-first reasons should be recorded")
    assertTrue(next(stats.pipelineV2DeployFirstEarlySecondReasonCounts or {}) ~= nil, "early second-action reasons should be recorded")
    assertTrue((tonumber(stats.pipelineV2PositionHints) or 0) > 0, "V2 should export its candidates for diagnostics")
end)

runTest("v2_early_does_not_call_legacy_early_planner_scoring", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 2

    local earlyPlanner = require("ai_tournament.early_planner")
    local originalScoreCandidate = earlyPlanner.scoreCandidate
    local originalScoreDeploy = earlyPlanner.scoreDeploy
    local originalApplyDemandBias = earlyPlanner.applyDemandBias
    local calls = {
        candidate = 0,
        deploy = 0,
        demand = 0
    }

    local function restore()
        earlyPlanner.scoreCandidate = originalScoreCandidate
        earlyPlanner.scoreDeploy = originalScoreDeploy
        earlyPlanner.applyDemandBias = originalApplyDemandBias
    end

    local ok, sequence, meta = pcall(function()
        earlyPlanner.scoreCandidate = function()
            calls.candidate = calls.candidate + 1
            error("legacy early candidate scoring should not run in V2 early", 2)
        end
        earlyPlanner.scoreDeploy = function()
            calls.deploy = calls.deploy + 1
            error("legacy early deploy scoring should not run in V2 early", 2)
        end
        earlyPlanner.applyDemandBias = function()
            calls.demand = calls.demand + 1
            error("legacy early demand bias should not run in V2 early", 2)
        end

        local ai = mkAI(2)
        return choose(ai, earlyBuildPositionState())
    end)

    restore()
    if not ok then
        error(sequence, 0)
    end

    local stats = meta.stats or {}
    assertEquals(meta.reason, "pipeline_v2_selected", "test should exercise the V2 early path")
    assertTrue(#sequence == 2, "V2 should still return a complete two-action candidate")
    assertEquals(calls.candidate, 0, "legacy candidate scorer should not be called")
    assertEquals(calls.deploy, 0, "legacy deploy scorer should not be called")
    assertEquals(calls.demand, 0, "legacy demand bias should not be called")
    assertTrue(
        (tonumber(stats.pipelineV2EarlyPlannerCandidateScoreSkipped) or 0) > 0,
        "candidate scoring skip should be observable"
    )
    assertTrue(
        (tonumber(stats.pipelineV2EarlyPlannerDeployScoreSkipped) or 0) > 0,
        "deploy scoring skip should be observable"
    )
    assertTrue(
        (tonumber(stats.pipelineV2EarlyPlannerDemandBiasSkipped) or 0) > 0,
        "demand bias skip should be observable"
    )
end)

runTest("v2_early_owns_soft_combat_scope_without_hidden_generator", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    local ai = mkAI(1)
    local _, meta = choose(ai, pureCombatState())
    local stats = meta.stats or {}

    assertEquals(meta.reason, "pipeline_v2_selected", "soft early combat scope should stay in V2")
    assertEquals(meta.contract, "BUILD_POSITION", "soft combat should not steal early BUILD_POSITION")
    assertTrue(stats.pipelineV2Skipped ~= true, "V2 should not skip soft early combat scope")
    assertTrue(stats.pipelineV2FailedReason ~= "non_build_position_contract", "soft combat should not fall into V1")
    assertTrue(isEarlyPositionSource(stats.selectedCandidateSource), "selection should come from V2 early-position candidates")
    assertTrue(stats.selectedCandidateSource ~= nil, "early should expose its selected V2 candidate source")
    assertTrue(stats.fallbackSource ~= "technical_fallback", "soft early combat should not use technical fallback")
    assertNoNormalFullTurnCompetition(stats)
end)

runTest("nonlethal_defense_pressure_stays_soft_for_v2", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 2
    local ai = mkAI(2)
    local state = baseState({
        actingPlayer = 2,
        turnNumber = 1,
        currentTurn = 1,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 5, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 7, col = 6, currentHp = 12, startingHp = 12},
        units = {
            unit("Earthstalker", 1, 3, 5),
            unit("Cloudstriker", 1, 1, 6),
            unit("Earthstalker", 2, 7, 5)
        },
        neutralBuildings = {
            {row = 3, col = 1},
            {row = 4, col = 4},
            {row = 5, col = 2},
            {row = 6, col = 2}
        },
        supply = {
            [1] = {supply("Cloudstriker"), supply("Earthstalker")},
            [2] = {supply("Cloudstriker"), supply("Earthstalker"), supply("Wingstalker")}
        }
    })

    local _, meta = choose(ai, state)
    local stats = meta.stats or {}

    assertEquals(stats.defenseKind, "pressure", "fixture should create non-lethal pressure")
    assertTrue(stats.defensePressureSoftenedForV2 == true, "non-lethal pressure should enter V2 as a soft weight")
    assertTrue(stats.pipelineV2Skipped ~= true, "V2 should not be skipped by soft pressure")
    assertTrue(stats.pipelineV2FailedReason ~= "hard_defense_contract", "soft pressure should not become a hard defense skip")
    assertTrue(meta.contract ~= "TECHNICAL_FALLBACK", "soft pressure should not fall into technical fallback")
    assertTrue(stats.fallbackSource ~= "technical_fallback", "soft pressure should not be played by the technical fallback")
    assertEquals(
        stats.selectedSoftDefensePressureReason,
        "soft_pressure_not_reduced",
        "fixture should select a non-reducing V2 position response"
    )
    assertEquals(
        meta.contractEvidence.passiveOverride.allowed,
        false,
        "non-reducing soft pressure must not be reported as a solved DEFEND_NOW proof"
    )
    assertEquals(
        meta.contractEvidence.selectedProofReason,
        "soft_pressure_not_reduced",
        "proof log should explain why active DEFEND_NOW stayed unresolved"
    )
end)

runTest("soft_defense_pressure_scoring_rewards_reduction", function()
    local scoreModel = require("ai_tournament.score")
    local softPressureScore = require("ai_tournament.pipeline_v2_soft_pressure_score")
    local ctx = {
        aiPlayer = 1,
        enemyPlayer = 2,
        score = scoreModel,
        stats = {},
        cfg = {
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_SCORING_ENABLED = true,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_NONREDUCING_PENALTY = 100,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_FALSE_RESPONSE_PENALTY = 50,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_WORSEN_PENALTY = 400,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_DAMAGE_WEIGHT = 10,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_REDUCED_BONUS = 80,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_CLEAR_BONUS = 70,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_REDUCTION_DAMAGE_WEIGHT = 20,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_ATTACKER_WEIGHT = 15
        },
        cache = {
            threat = function(_, state)
                return state and state.threat or nil
            end
        }
    }
    local contracts = {
        defenseKind = "pressure",
        defensePressureSoft = true,
        defenseThreat = {
            projectedDamage = 3,
            immediateDanger = true,
            damagingAttackers = {{id = "a"}}
        }
    }
    local candidate = {
        signature = "reduce_pressure",
        tacticalTags = {earlyPositionReason = "occupy_free_target"}
    }
    local score = scoreModel.finalize(scoreModel.new(candidate.signature))

    local scored = softPressureScore.apply(nil, {
        threat = {
            projectedDamage = 1,
            immediateDanger = true,
            damagingAttackers = {{id = "a"}}
        }
    }, ctx, contracts, candidate, score)

    assertTrue(candidate.tacticalTags.softDefensePressureReduced == true, "pressure should be marked reduced")
    assertEquals(candidate.tacticalTags.softDefensePressureReason, "soft_pressure_reduced", "reduction reason")
    assertEquals(candidate.tacticalTags.softDefensePressureBonus, 120, "reduction bonus should include damage delta")
    assertTrue(scored.survival > 0, "reduced pressure should improve survival score")
end)

runTest("soft_defense_pressure_scoring_penalizes_false_response", function()
    local scoreModel = require("ai_tournament.score")
    local softPressureScore = require("ai_tournament.pipeline_v2_soft_pressure_score")
    local function mkCtx()
        return {
            aiPlayer = 1,
            enemyPlayer = 2,
            score = scoreModel,
            stats = {},
            cfg = {
                PIPELINE_V2_SOFT_DEFENSE_PRESSURE_SCORING_ENABLED = true,
                PIPELINE_V2_SOFT_DEFENSE_PRESSURE_NONREDUCING_PENALTY = 100,
                PIPELINE_V2_SOFT_DEFENSE_PRESSURE_FALSE_RESPONSE_PENALTY = 50,
                PIPELINE_V2_SOFT_DEFENSE_PRESSURE_DAMAGE_WEIGHT = 10
            },
            cache = {
                threat = function(_, state)
                    return state and state.threat or nil
                end
            }
        }
    end
    local contracts = {
        defenseKind = "pressure",
        defensePressureSoft = true,
        defenseThreat = {
            projectedDamage = 3,
            immediateDanger = true,
            damagingAttackers = {{id = "a"}}
        }
    }
    local after = {
        threat = {
            projectedDamage = 3,
            immediateDanger = true,
            damagingAttackers = {{id = "a"}}
        }
    }
    local neutral = {
        signature = "neutral",
        tacticalTags = {earlyPositionReason = "occupy_free_target"}
    }
    local falseResponse = {
        signature = "false_response",
        tacticalTags = {earlyPositionReason = "move_release_occupant_then_complete_move_cover_pressure"}
    }

    softPressureScore.apply(nil, after, mkCtx(), contracts, neutral, scoreModel.finalize(scoreModel.new("neutral")))
    softPressureScore.apply(nil, after, mkCtx(), contracts, falseResponse, scoreModel.finalize(scoreModel.new("false")))

    assertEquals(neutral.tacticalTags.softDefensePressurePenalty, 130, "neutral non-reduction penalty")
    assertEquals(falseResponse.tacticalTags.softDefensePressurePenalty, 180, "false response should get extra penalty")
    assertEquals(
        falseResponse.tacticalTags.softDefensePressureReason,
        "soft_pressure_false_response",
        "pressure-looking move should be tagged as false response"
    )
end)

runTest("soft_defense_pressure_scoring_prefers_active_source_over_side_attack", function()
    local scoreModel = require("ai_tournament.score")
    local softPressureScore = require("ai_tournament.pipeline_v2_soft_pressure_score")
    local state = {
        units = {
            {name = "Crusher", player = 1, row = 4, col = 5, currentHp = 4, startingHp = 4, atkRange = 1, atkDamage = 2},
            {name = "Cloudstriker", player = 2, row = 5, col = 5, currentHp = 4, startingHp = 4, atkRange = 3, atkDamage = 2},
            {name = "Crusher", player = 2, row = 4, col = 4, currentHp = 4, startingHp = 4, atkRange = 1, atkDamage = 3}
        },
        commandHubs = {}
    }
    local function mkCtx()
        return {
            aiPlayer = 1,
            enemyPlayer = 2,
            currentState = state,
            score = scoreModel,
            stats = {},
            cfg = {
                PIPELINE_V2_SOFT_DEFENSE_PRESSURE_SCORING_ENABLED = true,
                PIPELINE_V2_SOFT_DEFENSE_PRESSURE_NONREDUCING_PENALTY = 100,
                PIPELINE_V2_SOFT_DEFENSE_PRESSURE_DAMAGE_WEIGHT = 10,
                PIPELINE_V2_SOFT_DEFENSE_SOURCE_DAMAGE_WEIGHT = 100,
                PIPELINE_V2_SOFT_DEFENSE_OFF_SOURCE_ATTACK_PENALTY = 200,
                PIPELINE_V2_SOFT_DEFENSE_AVAILABLE_RESPONSE_PENALTY = 30,
                PIPELINE_V2_SOFT_DEFENSE_SOURCE_RANGED_BONUS = 40,
                PIPELINE_V2_SOFT_DEFENSE_RANGED_DUEL_NONREDUCING_PENALTY = 0
            },
            cache = {
                threat = function(_, after)
                    return after and after.threat or nil
                end,
                simulate = function(_, current)
                    return current
                end
            }
        }
    end
    local ai = {
        calculateDamage = function(_, attacker)
            return attacker and attacker.atkDamage or 0
        end
    }
    local contracts = {
        defenseKind = "pressure",
        defensePressureSoft = true,
        directThreatAttackActions = 1,
        moveThreatAttackActions = 1,
        defenseThreat = {
            projectedDamage = 3,
            immediateDanger = true,
            damagingAttackers = {
                {unit = state.units[2]}
            }
        }
    }
    local after = {
        threat = {
            projectedDamage = 3,
            immediateDanger = true,
            damagingAttackers = {
                {unit = state.units[2]}
            }
        }
    }
    local sourceCandidate = {
        signature = "source",
        actions = {
            {type = "attack", unit = {row = 4, col = 5}, target = {row = 5, col = 5}}
        },
        tacticalTags = {}
    }
    local sideCandidate = {
        signature = "side",
        actions = {
            {type = "attack", unit = {row = 4, col = 5}, target = {row = 4, col = 4}}
        },
        tacticalTags = {}
    }

    local sourceScore = softPressureScore.apply(ai, after, mkCtx(), contracts, sourceCandidate, scoreModel.finalize(scoreModel.new("source")))
    local sideScore = softPressureScore.apply(ai, after, mkCtx(), contracts, sideCandidate, scoreModel.finalize(scoreModel.new("side")))

    assertTrue(sourceCandidate.tacticalTags.softDefenseSourceTargeted == true, "source attack should be recognized")
    assertEquals(sourceCandidate.tacticalTags.softDefensePressureReason, "soft_pressure_source_chipped")
    assertEquals(sideCandidate.tacticalTags.softDefensePressureReason, "soft_pressure_off_source_attack")
    assertTrue(sourceScore.total > sideScore.total, "non-lethal source pressure should beat an off-source side attack")
end)

runTest("soft_defense_pressure_scoring_penalizes_nonreducing_ranged_duel", function()
    local scoreModel = require("ai_tournament.score")
    local softPressureScore = require("ai_tournament.pipeline_v2_soft_pressure_score")
    local threatUnit = {
        name = "Cloudstriker",
        player = 2,
        row = 5,
        col = 5,
        currentHp = 4,
        startingHp = 4,
        atkRange = 3,
        atkDamage = 2
    }
    local state = {
        units = {
            {name = "Cloudstriker", player = 1, row = 2, col = 5, currentHp = 4, startingHp = 4, atkRange = 3, atkDamage = 2},
            threatUnit
        },
        commandHubs = {}
    }
    local ctx = {
        aiPlayer = 1,
        enemyPlayer = 2,
        currentState = state,
        score = scoreModel,
        stats = {},
        cfg = {
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_SCORING_ENABLED = true,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_NONREDUCING_PENALTY = 100,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_DAMAGE_WEIGHT = 10,
            PIPELINE_V2_SOFT_DEFENSE_SOURCE_DAMAGE_WEIGHT = 0,
            PIPELINE_V2_SOFT_DEFENSE_RANGED_DUEL_NONREDUCING_PENALTY = 55,
            PIPELINE_V2_SOFT_DEFENSE_RANGED_DUEL_FUTILE_PENALTY = 0
        },
        cache = {
            threat = function(_, after)
                return after and after.threat or nil
            end,
            simulate = function(_, current)
                return current
            end
        }
    }
    local contracts = {
        defenseKind = "pressure",
        defensePressureSoft = true,
        defenseThreat = {
            projectedDamage = 3,
            immediateDanger = true,
            damagingAttackers = {
                {unit = threatUnit}
            }
        }
    }
    local candidate = {
        signature = "ranged_duel",
        actions = {
            {type = "attack", unit = {row = 2, col = 5}, target = {row = 5, col = 5}}
        },
        tacticalTags = {}
    }

    softPressureScore.apply({
        calculateDamage = function(_, attacker)
            return attacker and attacker.atkDamage or 0
        end
    }, {
        threat = {
            projectedDamage = 3,
            immediateDanger = true,
            damagingAttackers = {
                {unit = threatUnit}
            }
        }
    }, ctx, contracts, candidate, scoreModel.finalize(scoreModel.new("ranged_duel")))

    assertTrue(candidate.tacticalTags.softDefenseRangedDuelNonReducing == true, "non-reducing ranged duel should be tagged")
    assertEquals(candidate.tacticalTags.softDefensePressureReason, "soft_pressure_ranged_duel_nonreducing")
    assertEquals(candidate.tacticalTags.softDefensePressurePenalty, 185, "ranged duel penalty should stack onto non-reduction")
end)

runTest("soft_defense_ranged_response_rewards_setup_kill_over_futile_duel", function()
    local scoreModel = require("ai_tournament.score")
    local softPressureScore = require("ai_tournament.pipeline_v2_soft_pressure_score")
    local threatUnit = {
        name = "Cloudstriker",
        player = 2,
        row = 5,
        col = 5,
        currentHp = 4,
        startingHp = 4,
        atkRange = 3,
        atkDamage = 2
    }
    local state = {
        units = {
            {name = "Cloudstriker", player = 1, row = 2, col = 5, currentHp = 4, startingHp = 4, atkRange = 3, atkDamage = 2},
            {name = "Earthstalker", player = 1, row = 5, col = 4, currentHp = 3, startingHp = 3, atkRange = 1, atkDamage = 2},
            threatUnit
        },
        commandHubs = {}
    }
    local after = {
        units = state.units,
        commandHubs = {},
        threat = {
            projectedDamage = 3,
            immediateDanger = true,
            damagingAttackers = {
                {unit = threatUnit}
            }
        }
    }
    local ctx = {
        aiPlayer = 1,
        enemyPlayer = 2,
        currentState = state,
        score = scoreModel,
        stats = {},
        cfg = {
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_SCORING_ENABLED = true,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_NONREDUCING_PENALTY = 100,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_DAMAGE_WEIGHT = 10,
            PIPELINE_V2_SOFT_DEFENSE_SOURCE_DAMAGE_WEIGHT = 0,
            PIPELINE_V2_SOFT_DEFENSE_RANGED_DUEL_NONREDUCING_PENALTY = 0,
            PIPELINE_V2_SOFT_DEFENSE_RANGED_SOURCE_SETUP_KILL_BONUS = 300,
            PIPELINE_V2_SOFT_DEFENSE_RANGED_SOURCE_SETUP_DAMAGE_WEIGHT = 25,
            PIPELINE_V2_SOFT_DEFENSE_RANGED_DUEL_FUTILE_PENALTY = 80
        },
        cache = {
            threat = function(_, candidateAfter)
                return candidateAfter and candidateAfter.threat or nil
            end,
            simulate = function(_, current)
                return current
            end
        }
    }
    local ai = {
        calculateDamage = function(_, attacker)
            return attacker and attacker.atkDamage or 0
        end
    }
    local contracts = {
        defenseKind = "pressure",
        defensePressureSoft = true,
        defenseThreat = {
            projectedDamage = 3,
            immediateDanger = true,
            damagingAttackers = {
                {unit = threatUnit}
            }
        }
    }
    local candidate = {
        signature = "setup_duel",
        actions = {
            {type = "attack", unit = {row = 2, col = 5}, target = {row = 5, col = 5}}
        },
        tacticalTags = {}
    }

    local scored = softPressureScore.apply(ai, after, ctx, contracts, candidate, scoreModel.finalize(scoreModel.new("setup_duel")))

    assertTrue(candidate.tacticalTags.softDefenseRangedResponseSetupKill == true, "support kill setup should be tagged")
    assertEquals(candidate.tacticalTags.softDefensePressureReason, "soft_pressure_ranged_setup_kill")
    assertTrue(candidate.tacticalTags.softDefenseRangedResponseBonus > 0, "setup should create response bonus")
    assertTrue(scored.total > -130, "setup response should beat the plain non-reduction penalty")
end)

runTest("hard_defense_recovery_context_relaxes_lethal_for_v2", function()
    local defenseScope = require("ai_tournament.defense_pressure_scope")
    local ctx = {stats = {}}
    local contracts = {
        defenseActive = true,
        defenseKind = "lethal",
        activeNames = {"DEFEND_NOW", "BUILD_POSITION"},
        defenseThreat = {
            immediateLethal = true,
            projectedDamage = 12,
            damagingAttackers = {{id = "threat"}}
        }
    }

    local result = defenseScope.withRelaxedHardDefenseContext(
        ctx,
        contracts,
        "hard_defense_no_sanitized_candidate",
        function(runtimeContracts)
            assertTrue(runtimeContracts.defenseActive ~= true, "relaxed context should let V2 score legal moves")
            assertTrue(runtimeContracts.defenseLethalSoft == true, "lethal pressure should become a score weight")
            assertEquals(runtimeContracts.activeNames[1], "BUILD_POSITION", "DEFEND_NOW should be removed from soft active names")
            return "ok"
        end
    )

    assertEquals(result, "ok", "relaxed context should return callback value")
    assertTrue(ctx.stats.defenseHardRelaxedForV2 == true, "stats should expose hard-defense recovery")
    assertEquals(
        ctx.stats.defenseHardRelaxedReason,
        "hard_defense_no_sanitized_candidate",
        "stats should preserve the recovery reason"
    )
    assertTrue(contracts.defenseActive == true, "original hard contract must stay unchanged")
end)

runTest("relaxed_lethal_scoring_penalizes_unresolved_immediate_loss", function()
    local scoreModel = require("ai_tournament.score")
    local softPressureScore = require("ai_tournament.pipeline_v2_soft_pressure_score")
    local ctx = {
        aiPlayer = 1,
        enemyPlayer = 2,
        score = scoreModel,
        stats = {},
        cfg = {
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_SCORING_ENABLED = true,
            PIPELINE_V2_SOFT_DEFENSE_LETHAL_UNRESOLVED_PENALTY = 1000,
            PIPELINE_V2_SOFT_DEFENSE_LETHAL_DAMAGE_WEIGHT = 10,
            PIPELINE_V2_SOFT_DEFENSE_LETHAL_ATTACKER_WEIGHT = 5,
            PIPELINE_V2_SOFT_DEFENSE_LETHAL_CLEARED_BONUS = 500,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_REDUCED_BONUS = 0,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_REDUCTION_DAMAGE_WEIGHT = 0,
            PIPELINE_V2_SOFT_DEFENSE_PRESSURE_ATTACKER_WEIGHT = 0
        },
        cache = {
            threat = function(_, after)
                return after and after.threat or nil
            end
        }
    }
    local contracts = {
        defenseKind = "lethal",
        defenseLethalSoft = true,
        defenseThreat = {
            immediateLethal = true,
            projectedDamage = 12,
            damagingAttackers = {{id = "a"}, {id = "b"}}
        }
    }
    local candidate = {
        signature = "still_dead",
        tacticalTags = {}
    }

    local scored = softPressureScore.apply(nil, {
        threat = {
            immediateLethal = true,
            projectedDamage = 6,
            damagingAttackers = {{id = "a"}}
        }
    }, ctx, contracts, candidate, scoreModel.finalize(scoreModel.new("still_dead")))

    assertTrue(candidate.tacticalTags.softDefenseLethal == true, "candidate should be tagged as soft lethal defense")
    assertTrue(candidate.tacticalTags.allowsImmediateLoss == true, "unresolved lethal should stay visible")
    assertEquals(candidate.tacticalTags.softDefensePressureReason, "soft_lethal_not_resolved", "reason should be explicit")
    assertTrue(scored.total < -1000, "unresolved immediate loss should receive a heavy score penalty")
end)

runTest("hard_defense_contract_stays_outside_v2_build_position", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    local ai = mkAI(1)
    local _, meta = choose(ai, immediateDefenseState())
    local stats = meta.stats or {}

    assertEquals(meta.contract, "DEFEND_NOW", "urgent defense should still be owned by hard")
    assertTrue(stats.pipelineV2Skipped == true, "V2 build-position path should skip hard defense")
    assertEquals(stats.pipelineV2FailedReason, "hard_defense_contract", "V2 skip reason should identify hard defense")
    assertTrue(stats.fallbackSource ~= "technical_fallback", "hard defense must not use technical fallback")
end)

runTest("hard_defense_zero_damage_only_proof_falls_back_to_ranked_candidates", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    GAME.CURRENT.TURN = 8
    local ai = mkAI(1)
    if ai.setAiReference then
        ai:setAiReference("base", "v2_zero_damage_proof_smoke")
    end
    local state = baseState({
        actingPlayer = 1,
        turnNumber = 8,
        currentTurn = 8,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 7, col = 4, currentHp = 12, startingHp = 12},
        units = {
            unit("Bastion", 1, 2, 3, {currentHp = 5}),
            unit("Artillery", 1, 4, 1),
            unit("Bastion", 2, 1, 3, {currentHp = 4}),
            unit("Artillery", 2, 5, 3),
            unit("Cloudstriker", 2, 7, 3),
            unit("Cloudstriker", 2, 7, 5)
        },
        neutralBuildings = {},
        supply = {
            [1] = {},
            [2] = {}
        }
    })

    local sequence, meta = choose(ai, state)
    local stats = meta.stats or {}
    local signature = ai.buildActionSequenceSignature and ai:buildActionSequenceSignature(sequence or {}) or ""

    assertTrue(meta.contract ~= "TECHNICAL_FALLBACK", "zero-damage proof must not force the technical fallback")
    assertTrue(stats.fallbackSource ~= "technical_fallback", "ranked tournament candidates should own recovery")
    assertTrue(
        stats.hardSelectionRejectReason ~= "hard_selection_sanitize_rejected",
        "zero-damage-only proof should be rejected before hard sanitizer failure"
    )
    assertTrue(
        signature:find("attack:2,3->1,3", 1, true) == nil,
        "zero-damage threat attack should not become the selected defense proof"
    )
end)

runTest("defense_guaranteed_fallback_replans_second_action_after_block", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 2
    local ai = mkAI(2)
    local state = baseState({
        actingPlayer = 2,
        turnNumber = 4,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 7, col = 3, currentHp = 12, startingHp = 12},
        units = {
            unit("Crusher", 1, 4, 2),
            unit("Earthstalker", 1, 4, 3),
            unit("Wingstalker", 2, 7, 2),
            unit("Earthstalker", 2, 7, 5),
            unit("Earthstalker", 2, 6, 4)
        },
        neutralBuildings = {
            {row = 3, col = 8},
            {row = 4, col = 7},
            {row = 5, col = 4},
            {row = 6, col = 2}
        },
        supply = {
            [1] = {supply("Wingstalker"), supply("Crusher")},
            [2] = {supply("Cloudstriker"), supply("Crusher"), supply("Earthstalker"), supply("Wingstalker")}
        }
    })

    local turnEnumerator = require("ai_tournament.turn_enumerator")
    local ctx = {
        aiPlayer = 2,
        enemyPlayer = 1,
        cfg = {
            DEFEND_NOW_AVOID_UNSAFE_FILLER = true,
            MAX_FIRST_ACTIONS = 1,
            MAX_SECOND_ACTIONS = 1,
            MAX_OWN_CANDIDATES = 1,
            MAX_DEPLOY_ACTIONS_PER_STATE = 24
        },
        stats = {},
        shouldStop = function() return true end,
        supplyPlanner = require("ai_tournament.supply_planner"),
        candidateBuckets = require("ai_tournament.candidate_buckets"),
        threatModel = require("ai_tournament.threat_model"),
        phase = {early = true}
    }
    ctx.cache = require("ai_tournament.cache").new(ctx)

    local disabledCandidates = turnEnumerator.generateFullTurnCandidates(ai, state, 2, ctx, {
        maxCandidates = 1,
        maxFirstActions = 1,
        maxSecondActions = 1,
        avoidMoveAttackExposure = true
    })
    assertEquals(#disabledCandidates, 0, "guaranteed fallback should be disabled by default")

    ctx.cfg.FULL_TURN_GUARANTEED_FALLBACK_ENABLED = true
    local candidates = turnEnumerator.generateFullTurnCandidates(ai, state, 2, ctx, {
        maxCandidates = 1,
        maxFirstActions = 1,
        maxSecondActions = 1,
        avoidMoveAttackExposure = true
    })
    local candidate = candidates[1]
    assertTrue(candidate ~= nil, "expected guaranteed fallback candidate")
    assertEquals(candidate.source, "full_turn_guaranteed_fallback", "test should exercise the technical fallback candidate")
    assertTrue(#(candidate.actions or {}) == 2, "guaranteed fallback should still return a full two-action turn")

    local currentState = state
    for _, action in ipairs(candidate.actions or {}) do
        assertTrue(
            not (
                action.type == "move"
                and action.unit and action.target
                and action.unit.row == 7 and action.unit.col == 5
                and action.target.row == 5 and action.target.col == 5
            ),
            "fallback must not reuse the stale unsafe E7->E5 filler move"
        )
        if action.type == "move" then
            local mover = ai:getUnitAtPosition(currentState, action.unit.row, action.unit.col)
            assertTrue(
                not ai:isSuicidalMovement(currentState, {row = action.target.row, col = action.target.col}, mover),
                "fallback second move should avoid lethal move+attack exposure"
            )
        end
        currentState = ctx.cache.simulate(ai, currentState, {action}, 2, ctx)
        assertTrue(currentState ~= nil, "fallback action should remain simulatable")
    end
end)

runTest("hard_direct_safe_kill_rejects_unsafe_second_filler", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 2
    local ai = mkAI(2)
    local state = baseState({
        actingPlayer = 2,
        turnNumber = 4,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 7, col = 3, currentHp = 12, startingHp = 12},
        units = {
            unit("Earthstalker", 1, 4, 3),
            unit("Crusher", 1, 5, 4, {currentHp = 1}),
            unit("Earthstalker", 2, 6, 4),
            unit("Earthstalker", 2, 7, 5)
        },
        neutralBuildings = {},
        supply = {
            [1] = {supply("Bastion")},
            [2] = {supply("Bastion")}
        }
    })

    local brain = require("ai_tournament.brain")
    local turnEnumerator = require("ai_tournament.turn_enumerator")
    local ctx = brain.buildContext(ai, state, {
        maxActions = 2,
        decisionStartTime = love.timer.getTime(),
        softBudgetMs = 900,
        hardBudgetMs = 1200
    })

    local originalRankAndSelect = ctx.candidateBuckets.rankAndSelect
    ctx.candidateBuckets.rankAndSelect = function(aiArg, stateArg, entries, playerId, ctxArg, opts)
        local ranked = originalRankAndSelect(aiArg, stateArg, entries, playerId, ctxArg, opts)
        if opts and opts.stage == "second" then
            table.sort(ranked, function(a, b)
                local sigA = turnEnumerator.actionSignature(a and a.action)
                local sigB = turnEnumerator.actionSignature(b and b.action)
                if sigA == "move:7,5>5,5" then return true end
                if sigB == "move:7,5>5,5" then return false end
                return sigA < sigB
            end)
        end
        return ranked
    end

    local item, _, rejectReason = brain._materializeHardPunishSelection(ai, state, ctx, {defenseActive = false}, {
        kind = "direct_safe_kill",
        reason = "hard_punish_safe_kill",
        proof = "safe_kill",
        targetName = "Crusher",
        actions = {
            {type = "attack", unit = {row = 6, col = 4}, target = {row = 5, col = 4}}
        }
    })
    ctx.candidateBuckets.rankAndSelect = originalRankAndSelect

    assertTrue(item ~= nil, "hard direct kill should still materialize with a safe filler")
    assertTrue(rejectReason == nil, "hard direct kill should not be rejected when a safe filler exists")
    assertTrue((tonumber(ctx.stats.hardPrefixFillerRejected) or 0) > 0, "unsafe filler should be explicitly rejected")
    assertEquals(ctx.stats.hardPrefixFillerRejectedReason, "unsafe_move_attack_exposure", "unsafe filler rejection reason")

    local currentState = state
    for _, action in ipairs((item.candidate and item.candidate.actions) or {}) do
        assertTrue(
            turnEnumerator.actionSignature(action) ~= "move:7,5>5,5",
            "hard direct kill must not keep the forced unsafe second move"
        )
        if action.type == "move" then
            local mover = ai:getUnitAtPosition(currentState, action.unit.row, action.unit.col)
            assertTrue(
                not ai:isSuicidalMovement(currentState, {row = action.target.row, col = action.target.col}, mover),
                "hard filler move should avoid lethal move+attack exposure"
            )
        end
        currentState = ctx.cache.simulate(ai, currentState, {action}, 2, ctx)
        assertTrue(currentState ~= nil, "hard filler action should remain simulatable")
    end
end)

runTest("hard_safe_move_attack_kill_preempts_v2_early_position", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    local ai = mkAI(1)
    local sequence, meta = choose(ai, baseState({
        actingPlayer = 1,
        turnNumber = 8,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            unit("Earthstalker", 1, 2, 3),
            unit("Earthstalker", 2, 5, 3)
        },
        neutralBuildings = {},
        supply = {
            [1] = {supply("Bastion")},
            [2] = {supply("Bastion")}
        }
    }))
    local stats = meta.stats or {}

    assertEquals(meta.reason, "hard_punish_safe_move_attack_kill", "safe move+attack kill should preempt V2")
    assertEquals(stats.coreExit, "hard_punish", "core exit should report hard punish")
    assertEquals(stats.hardSelectionLocked, true, "hard punish should hard-lock the safe kill")
    assertEquals(stats.hardSelectionReason, "safe_kill", "hard reason should match safe kill policy")
    assertTrue(stats.pipelineV2Enabled ~= true, "V2 should not run after hard punish selection")
    assertEquals(#sequence, 2, "move+attack punish should spend the full turn")
    assertEquals(sequence[1].type, "move", "first action should move into attack range")
    assertEquals(sequence[1].unit.row, 2, "move source row")
    assertEquals(sequence[1].unit.col, 3, "move source col")
    assertEquals(sequence[1].target.row, 4, "move target row")
    assertEquals(sequence[1].target.col, 3, "move target col")
    assertEquals(sequence[2].type, "attack", "second action should kill")
    assertEquals(sequence[2].unit.row, 4, "attack source row")
    assertEquals(sequence[2].unit.col, 3, "attack source col")
    assertEquals(sequence[2].target.row, 5, "attack target row")
    assertEquals(sequence[2].target.col, 3, "attack target col")
    assertTrue((tonumber(stats.selectedKillCount) or 0) > 0, "selected attack should kill the exposed unit")
end)

runTest("hard_direct_safe_kill_preempts_v2_early_position", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    local ai = mkAI(1)
    local sequence, meta = choose(ai, baseState({
        actingPlayer = 1,
        turnNumber = 8,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            unit("Earthstalker", 1, 4, 3),
            unit("Earthstalker", 2, 5, 3)
        },
        neutralBuildings = {},
        supply = {
            [1] = {supply("Bastion")},
            [2] = {supply("Bastion")}
        }
    }))
    local stats = meta.stats or {}

    assertEquals(meta.reason, "hard_punish_safe_kill", "direct safe kill should preempt V2")
    assertEquals(stats.coreExit, "hard_punish", "core exit should report hard punish")
    assertEquals(stats.hardPunishSelectedKind, "direct_safe_kill", "selected hard punish should be direct")
    assertTrue(stats.pipelineV2Enabled ~= true, "V2 should not run after direct hard punish selection")
    assertEquals(sequence[1].type, "attack", "first action should be the direct kill")
    assertEquals(sequence[1].unit.row, 4, "attack source row")
    assertEquals(sequence[1].unit.col, 3, "attack source col")
    assertEquals(sequence[1].target.row, 5, "attack target row")
    assertEquals(sequence[1].target.col, 3, "attack target col")
    assertTrue((tonumber(stats.selectedKillCount) or 0) > 0, "selected direct attack should kill the exposed unit")
end)

runTest("hard_safe_ranged_commandant_pressure_preempts_v2_early_position", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    local ai = mkAI(1)
    local sequence, meta = choose(ai, baseState({
        actingPlayer = 1,
        turnNumber = 4,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 4, col = 4, currentHp = 12, startingHp = 12},
        units = {
            unit("Artillery", 1, 4, 1),
            unit("Bastion", 2, 8, 8)
        },
        neutralBuildings = {},
        supply = {
            [1] = {supply("Bastion")},
            [2] = {supply("Bastion")}
        }
    }))
    local stats = meta.stats or {}

    assertEquals(meta.reason, "hard_punish_ranged_commandant_pressure", "safe ranged Commandant shot should preempt V2")
    assertEquals(stats.coreExit, "hard_punish", "core exit should report hard ranged pressure")
    assertEquals(stats.hardSelectionReason, "safe_commandant_pressure", "hard reason should not pretend this is a kill")
    assertEquals(stats.hardPunishSelectedKind, "ranged_commandant_pressure", "selected hard punish should be direct ranged pressure")
    assertTrue(stats.pipelineV2Enabled ~= true, "V2 should not run after hard ranged pressure selection")
    assertEquals(sequence[1].type, "attack", "first action should be the ranged shot")
    assertEquals(sequence[1].unit.row, 4, "attack source row")
    assertEquals(sequence[1].unit.col, 1, "attack source col")
    assertEquals(sequence[1].target.row, 4, "Commandant target row")
    assertEquals(sequence[1].target.col, 4, "Commandant target col")
    assertTrue((tonumber(stats.selectedCommandantDamage) or 0) > 0, "selected attack should damage Commandant")
end)

runTest("hard_safe_move_ranged_commandant_pressure_preempts_v2_early_position", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    local ai = mkAI(1)
    local sequence, meta = choose(ai, baseState({
        actingPlayer = 1,
        turnNumber = 4,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 7, col = 3, currentHp = 12, startingHp = 12},
        units = {
            unit("Cloudstriker", 1, 2, 3),
            unit("Bastion", 2, 8, 8)
        },
        neutralBuildings = {},
        supply = {
            [1] = {supply("Bastion")},
            [2] = {supply("Bastion")}
        }
    }))
    local stats = meta.stats or {}

    assertEquals(meta.reason, "hard_punish_move_ranged_commandant_pressure", "safe move+shoot Commandant shot should preempt V2")
    assertEquals(stats.coreExit, "hard_punish", "core exit should report hard ranged pressure")
    assertEquals(stats.hardSelectionReason, "safe_commandant_pressure", "hard reason should not pretend this is a kill")
    assertEquals(stats.hardPunishSelectedKind, "move_ranged_commandant_pressure", "selected hard punish should be move ranged pressure")
    assertEquals(#sequence, 2, "move+shoot pressure should spend the full turn")
    assertEquals(sequence[1].type, "move", "first action should move into a firing lane")
    assertEquals(sequence[2].type, "attack", "second action should shoot Commandant")
    assertEquals(sequence[2].target.row, 7, "Commandant target row")
    assertEquals(sequence[2].target.col, 3, "Commandant target col")
    assertTrue((tonumber(stats.selectedCommandantDamage) or 0) > 0, "selected attack should damage Commandant")
end)

runTest("hard_priority00_last_enemy_unit_is_win_now", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    local ai = mkAI(1)
    local sequence, meta = choose(ai, baseState({
        actingPlayer = 1,
        turnNumber = 8,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            unit("Earthstalker", 1, 4, 3),
            unit("Earthstalker", 2, 5, 3)
        },
        neutralBuildings = {},
        supply = {
            [1] = {supply("Bastion")},
            [2] = {}
        }
    }))
    local stats = meta.stats or {}

    assertEquals(meta.reason, "hard_win_priority00_elimination", "last enemy kill should be hard win now")
    assertEquals(meta.contract, "WIN_NOW", "last enemy kill should use WIN_NOW contract")
    assertEquals(stats.coreExit, "hard_win", "core exit should report hard win")
    assertEquals(stats.hardSelectionReason, "win_now", "hard reason should be win_now")
    assertEquals(sequence[1].type, "attack", "win action should be attack")
    assertEquals(sequence[1].target.row, 5, "last enemy target row")
    assertEquals(sequence[1].target.col, 3, "last enemy target col")
end)

runTest("hard_two_unit_safe_kill_preempts_v2_early_position", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    local ai = mkAI(1)
    local sequence, meta = choose(ai, baseState({
        actingPlayer = 1,
        turnNumber = 8,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            unit("Bastion", 1, 4, 2),
            unit("Bastion", 1, 4, 4),
            unit("Crusher", 2, 4, 3, {currentHp = 2})
        },
        neutralBuildings = {},
        supply = {
            [1] = {supply("Bastion")},
            [2] = {supply("Bastion")}
        }
    }))
    local stats = meta.stats or {}

    assertEquals(meta.reason, "hard_punish_two_unit_safe_kill", "two-unit safe kill should preempt V2")
    assertEquals(stats.coreExit, "hard_punish", "core exit should report hard punish")
    assertEquals(stats.hardPunishSelectedKind, "two_unit_safe_kill", "selected hard punish should be two-unit")
    assertEquals(#sequence, 2, "two-unit kill should spend two actions")
    assertEquals(sequence[1].type, "attack", "first action should damage target")
    assertEquals(sequence[2].type, "attack", "second action should finish target")
    assertEquals(sequence[2].target.row, 4, "finish target row")
    assertEquals(sequence[2].target.col, 3, "finish target col")
    assertTrue((tonumber(stats.selectedKillCount) or 0) > 0, "two-unit hard punish should kill the target")
end)

runTest("hard_cloudstriker_los_safe_kill_preempts_v2_early_position", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    local ai = mkAI(1)
    local sequence, meta = choose(ai, baseState({
        actingPlayer = 1,
        turnNumber = 8,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            unit("Cloudstriker", 1, 4, 1),
            unit("Bastion", 1, 4, 2),
            unit("Bastion", 2, 4, 4, {currentHp = 1})
        },
        neutralBuildings = {},
        supply = {
            [1] = {supply("Bastion")},
            [2] = {supply("Bastion")}
        }
    }))
    local stats = meta.stats or {}

    assertEquals(meta.reason, "hard_punish_cloudstriker_los_safe_kill", "Cloudstriker LoS kill should preempt V2")
    assertEquals(stats.coreExit, "hard_punish", "core exit should report hard punish")
    assertEquals(stats.hardPunishSelectedKind, "cloudstriker_los_safe_kill", "selected hard punish should be Cloudstriker LoS")
    assertEquals(#sequence, 2, "Cloudstriker LoS kill should spend two actions")
    assertEquals(sequence[1].type, "move", "first action should clear line of sight")
    assertEquals(sequence[1].unit.row, 4, "mover source row")
    assertEquals(sequence[1].unit.col, 2, "mover source col")
    assertEquals(sequence[2].type, "attack", "second action should shoot through opened line")
    assertEquals(sequence[2].unit.row, 4, "Cloudstriker source row")
    assertEquals(sequence[2].unit.col, 1, "Cloudstriker source col")
    assertEquals(sequence[2].target.row, 4, "Cloudstriker target row")
    assertEquals(sequence[2].target.col, 4, "Cloudstriker target col")
    assertTrue((tonumber(stats.selectedKillCount) or 0) > 0, "Cloudstriker LoS hard punish should kill the target")
end)

runTest("endgame_pipeline_wraps_mid_tools_with_endgame_pressure", function()
    ensureHeadlessGlobals()

    local pipelineV2End = require("ai_tournament.pipeline_v2_end")
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonality = require("ai_tournament.mid_personality")
    local midAttackCandidates = require("ai_tournament.mid_attack_candidates")
    local midPositionCandidates = require("ai_tournament.mid_position_candidates")
    local midGate = require("ai_tournament.pipeline_v2_mid_gate")

    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonality.interpretMap
    local originalAttackGenerate = midAttackCandidates.generate
    local originalPositionGenerate = midPositionCandidates.generate
    local originalGateCheck = midGate.check

    local function restore()
        midPositionMap.build = originalBuild
        midPersonality.interpretMap = originalInterpret
        midAttackCandidates.generate = originalAttackGenerate
        midPositionCandidates.generate = originalPositionGenerate
        midGate.check = originalGateCheck
    end

    local ok, err = pcall(function()
        local attackCandidate = {
            source = "mid_v2_attack",
            signature = "end_attack",
            actions = {
                {
                    type = "attack",
                    unit = {name = "Crusher", player = 1, row = 4, col = 4},
                    target = {row = 4, col = 5}
                },
                {
                    type = "move",
                    unit = {name = "Wingstalker", player = 1, row = 2, col = 2},
                    target = {row = 3, col = 2}
                }
            },
            completeTurn = true,
            containsAttack = true,
            hasFactionAttack = true,
            tacticalTags = {midV2 = true},
            midTrade = {
                accepted = true,
                reason = "mid_trade_pressure",
                class = "pressure",
                score = 120,
                totalDamage = 2,
                factionAttackCount = 1,
                kills = 0,
                commandantDamage = 0,
                materialDelta = 12,
                hpTradeNet = 2,
                inflictedMaterial = 20,
                expectedLoss = 0,
                counterCredit = 0
            },
            _midAfterState = {
                units = {
                    unit("Crusher", 1, 4, 4),
                    unit("Wingstalker", 1, 3, 2),
                    unit("Bastion", 2, 4, 5)
                },
                commandHubs = {
                    [1] = {row = 1, col = 1, currentHp = 12, startingHp = 12},
                    [2] = {row = 8, col = 8, currentHp = 12, startingHp = 12}
                },
                neutralBuildings = {}
            }
        }

        local passiveCandidate = {
            source = "mid_v2_position",
            signature = "end_passive",
            actions = {
                {type = "move", unit = {name = "Wingstalker", player = 1, row = 2, col = 2}, target = {row = 3, col = 2}},
                {type = "move", unit = {name = "Crusher", player = 1, row = 4, col = 4}, target = {row = 5, col = 4}}
            },
            completeTurn = true,
            containsAttack = false,
            hasFactionAttack = false,
            tacticalTags = {midV2 = true, midPosition = true},
            midPosition = {
                accepted = true,
                reason = "mid_position_pressure",
                score = 5000,
                targetValue = 5000,
                pressureGain = 5000,
                exposureDamage = 0
            },
            _midAfterState = {
                units = {
                    unit("Wingstalker", 1, 3, 2),
                    unit("Crusher", 1, 5, 4),
                    unit("Bastion", 2, 4, 5)
                },
                commandHubs = {
                    [1] = {row = 1, col = 1, currentHp = 12, startingHp = 12},
                    [2] = {row = 8, col = 8, currentHp = 12, startingHp = 12}
                },
                neutralBuildings = {}
            }
        }

        midPositionMap.build = function()
            return {byKey = {}, cells = {}}
        end
        midPersonality.interpretMap = function()
            return {profile = {name = "test", thresholds = {}, weights = {attack = 1, trade = 1}}, byKey = {}}
        end
        midAttackCandidates.generate = function()
            return {attackCandidate}
        end
        midPositionCandidates.generate = function()
            return {passiveCandidate}
        end
        midGate.check = function()
            return true, "mid_gate_test_accept"
        end

        local ctx = nil
        ctx = {
            cfg = {
                PIPELINE_V2_MID_ENABLED = false,
                PIPELINE_V2_MID_GATE_EXTRA_MS = 123,
                PIPELINE_V2_MID_MAX_RANKED = 4,
                PIPELINE_V2_MID_MAX_FINALISTS = 2,
                PIPELINE_V2_ENDGAME_ENABLED = true,
                PIPELINE_V2_ENDGAME_FORCE_INTERACTION = true,
                PIPELINE_V2_ENDGAME_GATE_EXTRA_MS = 500,
                PIPELINE_V2_ENDGAME_ATTACK_EXTRA_MS = 250,
                PIPELINE_V2_ENDGAME_POSITION_EXTRA_MS = 500,
                PIPELINE_V2_ENDGAME_ATTACK_BONUS = 2400,
                PIPELINE_V2_ENDGAME_DAMAGE_WEIGHT = 520,
                PIPELINE_V2_ENDGAME_POSITION_ONLY_PENALTY = 1600
            },
            phase = {name = "endgame", endgame = true, mid = false, early = false, reason = "supply_empty_p1", supply = {[1] = 0, [2] = 2}},
            stats = {},
            aiPlayer = 1,
            enemyPlayer = 2,
            maxActions = 2,
            hardBudgetMs = 1200,
            beginStage = function() end,
            endStage = function() end,
            elapsedMs = function()
                return 1200
            end,
            remainingMs = function()
                return 0
            end,
            shouldStop = function()
                return false
            end,
            cache = {
                simulate = function(_, _, actions)
                    return {actions = actions, units = {}, commandHubs = {}, neutralBuildings = {}}
                end
            },
            score = require("ai_tournament.score")
        }

        local result = pipelineV2End.run({}, {}, ctx, {defenseActive = false}, {})
        assertTrue(result and result.item, "endgame V2 should select through its own wrapper")
        assertEquals(result.reason, "pipeline_v2_end_selected", "endgame wrapper should expose end reason")
        assertEquals(result.item.candidate.source, "end_v2_attack", "endgame should retag mid attack source")
        assertEquals(ctx.stats.pipelineV2EndSelectedOriginalSource, "mid_v2_attack", "original source should stay visible")
        assertEquals(ctx.stats.pipelineV2EndGateExtraMs, 500, "endgame should use its own gate budget")
        assertEquals(ctx.cfg.PIPELINE_V2_MID_GATE_EXTRA_MS, 123, "endgame budget override should be restored")
        assertTrue(ctx.stats.pipelineV2EndBestWasInteraction == true, "endgame should prefer accepted interaction over passive score")
    end)

    restore()
    if not ok then
        error(err, 0)
    end
end)

runTest("endgame_pipeline_materializes_candidates_through_context_cache", function()
    ensureHeadlessGlobals()

    local pipelineV2End = require("ai_tournament.pipeline_v2_end")
    local midPositionMap = require("ai_tournament.mid_position_map")
    local midPersonality = require("ai_tournament.mid_personality")
    local midAttackCandidates = require("ai_tournament.mid_attack_candidates")
    local midPositionCandidates = require("ai_tournament.mid_position_candidates")
    local midDeployCandidates = require("ai_tournament.mid_deploy_candidates")
    local midGate = require("ai_tournament.pipeline_v2_mid_gate")

    local originalBuild = midPositionMap.build
    local originalInterpret = midPersonality.interpretMap
    local originalAttackGenerate = midAttackCandidates.generate
    local originalPositionGenerate = midPositionCandidates.generate
    local originalDeployGenerate = midDeployCandidates.generate
    local originalGateCheck = midGate.check

    local function restore()
        midPositionMap.build = originalBuild
        midPersonality.interpretMap = originalInterpret
        midAttackCandidates.generate = originalAttackGenerate
        midPositionCandidates.generate = originalPositionGenerate
        midDeployCandidates.generate = originalDeployGenerate
        midGate.check = originalGateCheck
    end

    local ok, err = pcall(function()
        local candidate = {
            source = "mid_v2_attack",
            signature = "end_cache_attack",
            actions = {
                {
                    type = "attack",
                    unit = {name = "Crusher", player = 1, row = 4, col = 4},
                    target = {row = 4, col = 5}
                },
                {
                    type = "move",
                    unit = {name = "Wingstalker", player = 1, row = 2, col = 2},
                    target = {row = 3, col = 2}
                }
            },
            completeTurn = true,
            containsAttack = true,
            hasFactionAttack = true,
            tacticalTags = {midV2 = true},
            midTrade = {
                accepted = true,
                reason = "mid_trade_pressure",
                class = "pressure",
                score = 120,
                totalDamage = 2,
                factionAttackCount = 1,
                kills = 0,
                commandantDamage = 0,
                materialDelta = 12,
                hpTradeNet = 2,
                inflictedMaterial = 20,
                expectedLoss = 0,
                counterCredit = 0
            }
        }

        midPositionMap.build = function()
            return {byKey = {}, cells = {}}
        end
        midPersonality.interpretMap = function()
            return {profile = {name = "test", thresholds = {}, weights = {attack = 1, trade = 1}}, byKey = {}}
        end
        midAttackCandidates.generate = function()
            return {candidate}
        end
        midPositionCandidates.generate = function()
            return {}
        end
        midDeployCandidates.generate = function()
            return {}
        end
        midGate.check = function()
            return true, "mid_gate_test_accept"
        end

        local state = {
            units = {
                unit("Crusher", 1, 4, 4),
                unit("Wingstalker", 1, 2, 2),
                unit("Bastion", 2, 4, 5)
            },
            commandHubs = {
                [1] = {row = 1, col = 1, currentHp = 12, startingHp = 12},
                [2] = {row = 8, col = 8, currentHp = 12, startingHp = 12}
            },
            neutralBuildings = {}
        }
        local ai = {
            sanitizeActionSequenceForState = function(_, _, actions)
                return actions, {replacements = 0, reasonCounts = {}}
            end,
            simulateActionSequenceForPlayer = function()
                error("endgame V2 should not bypass ctx.cache.simulate", 2)
            end
        }
        local cacheCalls = 0
        local ctx = nil
        ctx = {
            cfg = {
                PIPELINE_V2_MID_ENABLED = false,
                PIPELINE_V2_MID_MAX_RANKED = 4,
                PIPELINE_V2_MID_MAX_FINALISTS = 2,
                PIPELINE_V2_ENDGAME_ENABLED = true,
                PIPELINE_V2_ENDGAME_GATE_EXTRA_MS = 0,
                PIPELINE_V2_ENDGAME_ATTACK_EXTRA_MS = 0,
                PIPELINE_V2_ENDGAME_POSITION_EXTRA_MS = 0
            },
            phase = {name = "endgame", endgame = true, mid = false, early = false, reason = "supply_empty_p1", supply = {[1] = 0, [2] = 1}},
            stats = {},
            aiPlayer = 1,
            enemyPlayer = 2,
            maxActions = 2,
            beginStage = function() end,
            endStage = function() end,
            shouldStop = function()
                return false
            end,
            cache = {
                simulate = function(simAi, simState, actions, playerId, simCtx)
                    cacheCalls = cacheCalls + 1
                    assertTrue(simAi == ai, "endgame cache should receive the active ai")
                    assertTrue(simState == state, "endgame cache should receive the original state")
                    assertEquals(playerId, 1, "endgame cache should use ai player id")
                    assertTrue(simCtx == ctx, "endgame cache should receive the same context")
                    return {
                        units = {
                            unit("Crusher", 1, 4, 4),
                            unit("Wingstalker", 1, 3, 2),
                            unit("Bastion", 2, 4, 5, {currentHp = 4})
                        },
                        commandHubs = state.commandHubs,
                        neutralBuildings = {},
                        actions = actions
                    }
                end
            },
            score = require("ai_tournament.score")
        }

        local result = pipelineV2End.run(ai, state, ctx, {defenseActive = false}, {})
        assertTrue(result and result.item, "endgame V2 should select the cached materialized candidate")
        assertEquals(result.item.candidate.source, "end_v2_attack", "candidate should still be retagged as endgame")
        assertTrue(cacheCalls > 0, "endgame materialization should call ctx.cache.simulate")
    end)

    restore()
    if not ok then
        error(err, 0)
    end
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    print("# Tournament V2 Emancipation Smoke")
    print("")
    print(string.format("- Generated: %s", os.date("%Y-%m-%d %H:%M:%S")))
    print(string.format("- Passed: %d", passCount))
    print(string.format("- Failed: %d", #results - passCount))
    print("")
    print("## Results")
    print("")

    for _, result in ipairs(results) do
        local status = result.ok and "PASS" or "FAIL"
        print(string.format("- `%s` %s (%.2fms)", status, result.name, result.ms))
        if not result.ok then
            print(string.format("  - Error: `%s`", tostring(result.err)))
        end
    end

    if passCount ~= #results then
        os.exit(1)
    end
end

buildReport()
