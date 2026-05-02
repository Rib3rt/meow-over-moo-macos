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

runTest("punish_map_cloudstriker_los_blocked", function()
    ensureHeadlessGlobals()
    local punishMap = require("ai_tournament.punish_map")
    local ai = mkAI(1)
    local cloud = unit("Cloudstriker", 1, 4, 1)
    local target = unit("Crusher", 2, 4, 4)
    local state = stateWith({cloud, target}, {{row = 4, col = 2}})

    local canAttack = punishMap._private.canAttackCellFrom(ai, state, cloud, cloud, target)
    assertTrue(canAttack == false, "Cloudstriker should not shoot through a blocker")
end)

runTest("punish_map_artillery_ignores_los", function()
    ensureHeadlessGlobals()
    local punishMap = require("ai_tournament.punish_map")
    local ai = mkAI(1)
    local artillery = unit("Artillery", 1, 4, 1)
    local target = unit("Crusher", 2, 4, 4)
    local state = stateWith({artillery, target}, {{row = 4, col = 2}})

    local canAttack = punishMap._private.canAttackCellFrom(ai, state, artillery, artillery, target)
    assertTrue(canAttack == true, "Artillery should ignore line-of-sight blockers")
end)

runTest("punish_map_move_attack_trap_detected", function()
    ensureHeadlessGlobals()
    local punishMap = require("ai_tournament.punish_map")
    local ai = mkAI(1)
    local exposed = unit("Crusher", 1, 4, 4)
    local enemy = unit("Earthstalker", 2, 6, 4)
    local state = stateWith({exposed, enemy})
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local analysis = punishMap.analyzeCell(state, ai, ctx, exposed, exposed)
    assertTrue(analysis.enemyBestReply ~= nil, "expected enemy punish")
    assertTrue(analysis.enemyBestReply.kind == "move_attack", "expected move+attack punish")
    assertTrue(analysis.enemyBestReply.lethal == true, "Earthstalker should be lethal into Crusher")
    assertTrue(analysis.covered == false, "uncovered trap should not be marked covered")
end)

runTest("punish_map_covered_interdiction_allowed", function()
    ensureHeadlessGlobals()
    local punishMap = require("ai_tournament.punish_map")
    local ai = mkAI(1)
    local exposed = unit("Crusher", 1, 4, 4)
    local cover = unit("Earthstalker", 1, 5, 3)
    local enemy = unit("Earthstalker", 2, 6, 4)
    local state = stateWith({exposed, cover, enemy})
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local analysis = punishMap.analyzeCell(state, ai, ctx, exposed, exposed)
    assertTrue(analysis.enemyBestReply ~= nil, "expected enemy punish")
    assertTrue(analysis.counterPunish ~= nil, "expected friendly counter-punish")
    assertTrue(analysis.covered == true, "covered interdiction should be allowed by perception")
    assertTrue(analysis.counterPunish.lethal == true, "cover should threaten a lethal recapture")
end)

runTest("punish_map_wounded_winner_retreat_hint", function()
    ensureHeadlessGlobals()
    local punishMap = require("ai_tournament.punish_map")
    local ai = mkAI(1)
    local wounded = unit("Crusher", 1, 4, 4, {currentHp = 1})
    local enemy = unit("Wingstalker", 2, 6, 4)
    local state = stateWith({wounded, enemy})
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local analysis = punishMap.analyzeCell(state, ai, ctx, wounded, wounded)
    assertTrue(analysis.retreat and analysis.retreat.useful == true, "low HP threatened winner should expose retreat hint")
end)

runTest("punish_map_build_marks_contested_cells", function()
    ensureHeadlessGlobals()
    local punishMap = require("ai_tournament.punish_map")
    local ai = mkAI(1)
    local ally = unit("Crusher", 1, 4, 3)
    local enemy = unit("Crusher", 2, 4, 5)
    local state = stateWith({ally, enemy})
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local built = punishMap.build(state, ai, ctx)
    assertTrue(built.contested["4,4"] ~= nil, "cell between opposing Crushers should be contested")
end)

runTest("punish_map_finds_strategic_free_cells", function()
    ensureHeadlessGlobals()
    local punishMap = require("ai_tournament.punish_map")
    local ai = mkAI(1)
    local ally = unit("Crusher", 1, 4, 3)
    local enemy = unit("Crusher", 2, 4, 5)
    local state = stateWith({ally, enemy})
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local strategic = punishMap.findStrategicFreeCells(state, ai, ctx, {maxCells = 8})
    local cell = strategic.byKey["4,4"]
    assertTrue(cell ~= nil, "expected contested free cell to be strategic")
    assertTrue(cell.free == true, "strategic cell should be free")
    assertTrue(cell.contested == true, "cell should be contested by both sides")
    assertTrue(cell.score > 0, "strategic cell should have positive score")
end)

runTest("punish_map_distinguishes_occupation_from_attack_influence", function()
    ensureHeadlessGlobals()
    local punishMap = require("ai_tournament.punish_map")
    local ai = mkAI(1)
    local ally = unit("Crusher", 1, 4, 3)
    local state = stateWith({ally})
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}
    local cell = {row = 4, col = 4}

    local influence = punishMap.analyzeCellInfluence(state, ai, ctx, cell)
    assertTrue(influence.occupied == false, "free cell should not be marked occupied")
    assertTrue(influence.control.us == false, "physical control means a unit occupies the cell")
    assertTrue(influence.attackInfluence.us.active == true, "adjacent Crusher should attack-influence the cell")

    local strategic = punishMap.findStrategicFreeCells(state, ai, ctx, {maxCells = 8})
    local strategicCell = strategic.byKey["4,4"]
    assertTrue(strategicCell ~= nil, "attack-influenced free cell should remain visible")
    assertTrue(strategicCell.control.us == false, "new control field should mean occupation, not attack coverage")
    assertTrue(strategicCell.attackInfluencedByUs == true, "new field should expose attack influence explicitly")
    assertTrue(strategicCell.controlledByUs == true, "compatibility alias stays attack influence")
end)

runTest("punish_map_tracks_deploy_and_heal_influence", function()
    ensureHeadlessGlobals()
    local punishMap = require("ai_tournament.punish_map")
    local ai = mkAI(1)
    local healer = unit("Healer", 1, 4, 3, {repair = true, repairRange = 1})
    local ally = unit("Crusher", 1, 4, 4, {currentHp = 2})
    local state = stateWith({healer, ally})
    state.supply[1] = {{name = "Bastion"}}
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local healInfluence = punishMap.analyzeCellInfluence(state, ai, ctx, {row = 4, col = 4})
    assertTrue(healInfluence.healInfluence.us.active == true, "Healer should heal-influence adjacent friendly cell")

    local deployInfluence = punishMap.analyzeCellInfluence(state, ai, ctx, {row = 1, col = 1})
    assertTrue(deployInfluence.deployInfluence.us.active == true, "supply should deploy-influence free hub-adjacent cell")
end)

runTest("punish_map_influence_prepares_next_turn_deploys", function()
    ensureHeadlessGlobals()
    local punishMap = require("ai_tournament.punish_map")
    local ai = mkAI(1)
    local state = stateWith({})
    state.hasDeployedThisTurn = true
    state.supply[1] = {{name = "Bastion"}}
    state.supply[2] = {{name = "Earthstalker"}}
    local ctx = {aiPlayer = 1, enemyPlayer = 2, phase = {name = "early"}}

    local ownInfluence = punishMap.analyzeCellInfluence(state, ai, ctx, {row = 1, col = 1})
    assertTrue(
        ownInfluence.deployInfluence.us.active == true,
        "own deploy influence should describe next turn, not current hasDeployedThisTurn"
    )
    assertTrue(
        ownInfluence.influencedByUs == false and ownInfluence.potentialInfluencedByUs == true,
        "deploy influence is potential, not hard influence"
    )

    local enemyInfluence = punishMap.analyzeCellInfluence(state, ai, ctx, {row = 8, col = 8})
    assertTrue(
        enemyInfluence.deployInfluence.enemy.active == true,
        "enemy deploy influence should also prepare the enemy next turn"
    )
    assertTrue(
        enemyInfluence.influencedByEnemy == false and enemyInfluence.potentialInfluencedByEnemy == true,
        "enemy deploy potential must not be treated as hard influence"
    )
end)

runTest("strategic_profile_interprets_same_cell_by_role", function()
    ensureHeadlessGlobals()
    local strategicProfile = require("ai_tournament.strategic_profile")
    local cell = {
        row = 4,
        col = 4,
        free = true,
        score = 220,
        kinds = {"support", "interdiction"},
        coveredIfOccupied = true
    }
    local opening = strategicProfile.scoreStrategicCell(cell, {
        phase = {name = "early"},
        earlyPlan = {role = "opening"}
    }, {action = "deploy"})
    local response = strategicProfile.scoreStrategicCell(cell, {
        phase = {name = "early"},
        earlyPlan = {role = "response"}
    }, {action = "deploy"})
    assertTrue(opening.value > response.value, "same perception should be interpreted differently by plan role")
    assertTrue(response.value > 0, "response should still value a good covered cell")
end)

runTest("strategic_profile_penalizes_uncovered_punish", function()
    ensureHeadlessGlobals()
    local strategicProfile = require("ai_tournament.strategic_profile")
    local cell = {
        row = 4,
        col = 4,
        free = true,
        score = 260,
        kinds = {"interdiction", "second_threat"},
        coveredIfOccupied = false,
        enemyPunish = {lethal = true}
    }
    local scored = strategicProfile.scoreStrategicCell(cell, {
        phase = {name = "early"},
        earlyPlan = {role = "opening"}
    }, {action = "move"})
    assertTrue(scored.value < 0, "uncovered lethal punish should beat strategic attractiveness")
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
    print(string.format("ai_tournament_punish_map_smoke failed: %d/%d", failed, #results))
    os.exit(1)
end

print(string.format("ai_tournament_punish_map_smoke passed: %d/%d", #results, #results))
