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
        }
    }

    _G.DEBUG = _G.DEBUG or {}
    DEBUG.AI = false

    _G.GAME = _G.GAME or {}
    GAME.CONSTANTS = GAME.CONSTANTS or {}
    GAME.CONSTANTS.GRID_SIZE = GAME.CONSTANTS.GRID_SIZE or 8
    GAME.CONSTANTS.MAX_ACTIONS_PER_TURN = GAME.CONSTANTS.MAX_ACTIONS_PER_TURN or 2
    GAME.CURRENT = GAME.CURRENT or {}
    GAME.CURRENT.TURN = GAME.CURRENT.TURN or 3
    GAME.CURRENT.AI_PLAYER_NUMBER = GAME.CURRENT.AI_PLAYER_NUMBER or 1
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
        currentTurn = 3,
        turnNumber = 3,
        units = units or {},
        neutralBuildings = neutralBuildings or {},
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

local function hasFact(cell, fact)
    for _, value in ipairs((cell and cell.facts) or {}) do
        if value == fact then
            return true
        end
    end
    return false
end

local function hasScoreReason(scored, reason)
    for _, item in ipairs((scored and scored.reasons) or {}) do
        if item.reason == reason or item == reason then
            return true
        end
    end
    return false
end

local function cellByKey(cells, key)
    for _, cell in ipairs(cells or {}) do
        if cell.key == key then
            return cell
        end
    end
    return nil
end

runTest("strategic_interpreter_is_neutral_about_control_and_influence", function()
    ensureHeadlessGlobals()
    local interpreter = require("ai_tournament.strategic_interpreter")
    local ai = mkAI(1)
    local state = stateWith({
        unit("Crusher", 1, 4, 3),
        unit("Crusher", 2, 4, 5)
    })
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local position = interpreter.interpret(state, ai, ctx)
    local cell = position.byKey["4,4"]
    assertTrue(position.purpose == nil, "neutral interpreter should not answer a goal by itself")
    assertTrue(cell ~= nil, "expected interpreted center cell")
    assertTrue(cell.control.us == false, "control means physical occupation")
    assertTrue(cell.attackInfluence.us.active == true, "cell should be attack-influenced by us")
    assertTrue(cell.attackInfluence.enemy.active == true, "cell should be attack-influenced by enemy")
    assertTrue(cell.attackContested == true, "opposing attack influence should mark attack contest")
    assertTrue(hasFact(cell, "attack_influence_us"), "facts should preserve neutral influence vocabulary")
end)

runTest("strategic_interpreter_tracks_deploy_and_heal_as_influence", function()
    ensureHeadlessGlobals()
    local interpreter = require("ai_tournament.strategic_interpreter")
    local ai = mkAI(1)
    local state = stateWith({
        unit("Healer", 1, 4, 3, {repair = true, repairRange = 1}),
        unit("Crusher", 1, 4, 4, {currentHp = 2})
    })
    state.supply[1] = {{name = "Bastion"}}
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local position = interpreter.interpret(state, ai, ctx)
    assertTrue(position.byKey["4,4"].healInfluence.us.active == true, "Healer should create heal influence")
    assertTrue(position.byKey["1,1"].deployInfluence.us.active == true, "supply should create deploy influence")
end)

runTest("strategic_personality_follows_ai_reference_when_enabled", function()
    ensureHeadlessGlobals()
    local aiConfig = require("ai_config")
    local questions = require("ai_tournament.strategic_questions")
    local cell = {
        key = "4,4",
        row = 4,
        col = 4,
        strategicScore = 500,
        progress = 4,
        opportunity = {
            secondThreat = true,
            safeStaging = true
        },
        risk = {
            enemyPunish = true,
            lethalPunish = false
        },
        moveInfluence = {us = {active = true}},
        deployInfluence = {us = {active = false}},
        attackInfluence = {enemy = {count = 1}},
        coveredIfOccupied = false
    }
    local cfg = aiConfig.AI_PARAMS.TOURNAMENT_AI
    local marge = questions.scoreCell(cell, "pressure", {
        ctx = {
            cfg = cfg,
            aiReference = "marge"
        }
    })
    local burns = questions.scoreCell(cell, "pressure", {
        ctx = {
            cfg = cfg,
            aiReference = "burns"
        }
    })

    assertTrue(marge.personality == "defensive_anchor", "Marge should map to defensive strategic personality")
    assertTrue(burns.personality == "maximum_aggression", "Burns should map to aggressive strategic personality")
    assertTrue(burns.value > marge.value, "aggressive profile should value pressure cells more than defensive profile")
end)

runTest("strategic_interpreter_keeps_deploy_as_potential_influence", function()
    ensureHeadlessGlobals()
    local interpreter = require("ai_tournament.strategic_interpreter")
    local ai = mkAI(1)
    local state = stateWith({})
    state.hasDeployedThisTurn = true
    state.supply[1] = {{name = "Bastion"}}
    state.supply[2] = {{name = "Earthstalker"}}
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local position = interpreter.interpret(state, ai, ctx)
    local ownCell = position.byKey["1,1"]
    local enemyCell = position.byKey["8,8"]
    assertTrue(ownCell and ownCell.deployInfluence.us.active == true, "own deploy potential should stay visible")
    assertTrue(enemyCell and enemyCell.deployInfluence.enemy.active == true, "enemy deploy potential should stay visible")
    assertTrue(ownCell.influencedByUs == false, "deploy potential should not become hard influence")
    assertTrue(enemyCell.influencedByEnemy == false, "enemy deploy potential should not become hard influence")
    assertTrue(ownCell.potentialInfluencedByUs == true, "own deploy potential should have explicit potential field")
    assertTrue(enemyCell.potentialInfluencedByEnemy == true, "enemy deploy potential should have explicit potential field")
end)

runTest("early_position_map_allows_other_owned_cells_as_support_cover", function()
    ensureHeadlessGlobals()
    local positionMap = require("ai_tournament.early_position_map")
    local ai = mkAI(1)
    local state = stateWith({
        unit("Earthstalker", 1, 2, 2),
        unit("Crusher", 1, 2, 3)
    })
    local ctx = {
        aiPlayer = 1,
        enemyPlayer = 2,
        phase = {name = "early"},
        earlyPlan = {intentId = "choke_lock", role = "opening"},
        cfg = {
            PIPELINE_V2_EARLY_STRICT_RESOLVED_COVER = true,
            PIPELINE_V2_EARLY_SAFE_CELL_POLICY_ENABLED = true,
            PIPELINE_V2_EARLY_STRATEGIC_MIN_VALUE = 120
        },
        stats = {}
    }

    local result = positionMap.build(ai, state, ctx, {limit = 8})
    local anchor = cellByKey(result.cells, "2,2")
    local advanced = cellByKey(result.cells, "2,3")
    assertTrue(anchor and anchor.status == "owned_covered", "another owned-cell occupant should count as cover")
    assertTrue(advanced and advanced.status == "owned_covered", "coverage can be reciprocal between two occupied cells")
end)

runTest("early_position_map_penalizes_only_cloudstriker_blocked_commandant_pressure", function()
    ensureHeadlessGlobals()
    local positionMap = require("ai_tournament.early_position_map")
    local policy = require("ai_tournament.early_position_cell_policy")
    local ai = mkAI(1)
    local state = stateWith({
        unit("Cloudstriker", 1, 5, 3),
        unit("Crusher", 2, 6, 3)
    })
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 5, currentHp = 12, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 7, col = 3, currentHp = 12, startingHp = 12}
    local ctx = {
        aiPlayer = 1,
        enemyPlayer = 2,
        phase = {name = "early"},
        earlyPlan = {intentId = "choke_lock", role = "opening"},
        cfg = {
            PIPELINE_V2_EARLY_SAFE_CELL_POLICY_ENABLED = true,
            PIPELINE_V2_EARLY_CLOUDSTRIKER_BLOCKED_PRESSURE_ENABLED = true,
            PIPELINE_V2_EARLY_CLOUDSTRIKER_BLOCKED_HOLD_PENALTY = 340,
            PIPELINE_V2_EARLY_STRATEGIC_MIN_VALUE = 120
        },
        stats = {}
    }

    local result = positionMap.build(ai, state, ctx, {limit = 8})
    local source = cellByKey(result.cells, "5,3")
    assertTrue(source and source.cloudstrikerBlockedPressure == true, "blocked Cloudstriker pressure should be detected")
    assertTrue(source.cloudstrikerBlockedPressureBlocker == "Crusher", "the blocking defender should be visible")
    assertTrue(hasScoreReason(source, "cloudstriker_blocked_pressure"), "blocked pressure should affect scoring")
    assertTrue(
        policy.isHoldableOccupiedStrategicCell(source, ctx) == false,
        "blocked nonlethal pressure should lower hold priority below normal early hold"
    )
end)

runTest("strategic_questions_use_same_position_for_different_purposes", function()
    ensureHeadlessGlobals()
    local questions = require("ai_tournament.strategic_questions")
    local staging = {
        key = "3,3",
        row = 3,
        col = 3,
        strategicScore = 100,
        progress = 3,
        coveredIfOccupied = true,
        opportunity = {safeStaging = true},
        risk = {},
        moveInfluence = {us = {active = true, count = 1}},
        deployInfluence = {us = {active = false, count = 0}},
        healInfluence = {us = {active = false, count = 0}},
        attackInfluence = {enemy = {active = false, count = 0}}
    }
    local deny = {
        key = "4,4",
        row = 4,
        col = 4,
        strategicScore = 100,
        progress = 0,
        coveredIfOccupied = true,
        attackContested = true,
        opportunity = {deny = true, interdiction = true},
        risk = {},
        moveInfluence = {us = {active = true, count = 1}},
        deployInfluence = {us = {active = false, count = 0}},
        healInfluence = {us = {active = false, count = 0}},
        attackInfluence = {enemy = {active = true, count = 1}}
    }
    local position = {
        kind = "neutral_position_interpretation",
        strategicFreeCells = {staging, deny}
    }

    local expand = questions.ask(position, "expand", {limit = 1})
    local contain = questions.ask(position, "contain", {limit = 1})
    assertTrue(expand.answers[1].key == "3,3", "expand should ask for staging from the same neutral facts")
    assertTrue(contain.answers[1].key == "4,4", "contain should ask for deny/interdiction from the same neutral facts")
end)

runTest("strategic_questions_can_ask_for_deploy_anchors", function()
    ensureHeadlessGlobals()
    local interpreter = require("ai_tournament.strategic_interpreter")
    local questions = require("ai_tournament.strategic_questions")
    local ai = mkAI(1)
    local state = stateWith({})
    state.supply[1] = {{name = "Bastion"}}
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local position = interpreter.interpret(state, ai, ctx)
    local answer = questions.ask(position, "deploy", {limit = 1})
    assertTrue(#answer.answers > 0, "deploy question should produce an answer")
    assertTrue(
        answer.answers[1].cell.deployInfluence.us.active == true,
        "deploy question should prefer a deploy-influenced cell"
    )
end)

runTest("strategic_questions_use_neutral_base_personality", function()
    ensureHeadlessGlobals()
    local questions = require("ai_tournament.strategic_questions")
    local staging = {
        key = "3,3",
        row = 3,
        col = 3,
        strategicScore = 100,
        progress = 2,
        coveredIfOccupied = true,
        opportunity = {safeStaging = true, support = true},
        risk = {},
        moveInfluence = {us = {active = true, count = 1}},
        deployInfluence = {us = {active = false, count = 0}},
        healInfluence = {us = {active = false, count = 0}},
        attackInfluence = {enemy = {active = false, count = 0}}
    }
    local scored = questions.scoreCell(staging, "expand", {
        ctx = {cfg = {STRATEGIC_PERSONALITY = "neutral_base"}}
    })

    assertTrue(scored.personality == "neutral_base", "question scoring should expose neutral_base")
    assertTrue(
        hasScoreReason(scored, "personality_neutral_base"),
        "question scoring should record which personality interpreted the facts"
    )
end)

runTest("neutral_base_prefers_safe_presence_over_uncovered_lure", function()
    ensureHeadlessGlobals()
    local questions = require("ai_tournament.strategic_questions")
    local safe = {
        key = "3,3",
        row = 3,
        col = 3,
        strategicScore = 80,
        progress = 2,
        coveredIfOccupied = true,
        opportunity = {safeStaging = true, support = true},
        risk = {},
        moveInfluence = {us = {active = true, count = 1}},
        deployInfluence = {us = {active = false, count = 0}},
        healInfluence = {us = {active = false, count = 0}},
        attackInfluence = {enemy = {active = false, count = 0}}
    }
    local lure = {
        key = "4,4",
        row = 4,
        col = 4,
        strategicScore = 180,
        progress = 4,
        coveredIfOccupied = false,
        opportunity = {safeStaging = true, secondThreat = true},
        risk = {enemyPunish = true, lethalPunish = true},
        moveInfluence = {us = {active = true, count = 1}},
        deployInfluence = {us = {active = false, count = 0}},
        healInfluence = {us = {active = false, count = 0}},
        attackInfluence = {enemy = {active = true, count = 2}}
    }

    local safeScore = questions.scoreCell(safe, "expand", {ctx = {cfg = {STRATEGIC_PERSONALITY = "neutral_base"}}})
    local lureScore = questions.scoreCell(lure, "expand", {ctx = {cfg = {STRATEGIC_PERSONALITY = "neutral_base"}}})
    assertTrue(
        safeScore.value > lureScore.value,
        "neutral_base should treat exposed high-score cells as punishable, not automatic progress"
    )
end)

local failed = 0
for _, result in ipairs(results) do
    if result.ok then
        print(string.format("[PASS] %s (%.2f ms)", result.name, result.ms))
    else
        failed = failed + 1
        print(string.format("[FAIL] %s (%.2f ms)", result.name, result.ms))
        print(result.err)
    end
end

if failed > 0 then
    print(string.format("ai_tournament_strategic_interpreter_smoke failed: %d/%d", failed, #results))
    os.exit(1)
end

print(string.format("ai_tournament_strategic_interpreter_smoke passed: %d/%d", #results, #results))
