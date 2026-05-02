package.path = package.path .. ";./?.lua"

local results = {}

local function runTest(name, fn)
    local startedAt = os.clock()
    local ok, err = xpcall(fn, debug.traceback)
    local elapsedMs = (os.clock() - startedAt) * 1000
    results[#results + 1] = {
        name = name,
        ok = ok,
        err = err,
        ms = elapsedMs
    }
end

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format(
            "%s (expected=%s actual=%s)",
            message or "assertEquals failed",
            tostring(expected),
            tostring(actual)
        ), 2)
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

local function newCtx(aiPlayer)
    local score = require("ai_tournament.score")
    local cache = require("ai_tournament.cache")
    local evaluator = require("ai_tournament.evaluator")
    local ctx = {
        cfg = {},
        aiPlayer = aiPlayer,
        enemyPlayer = aiPlayer == 1 and 2 or 1,
        score = score,
        reserveModel = require("ai_tournament.reserve_model"),
        supplyPlanner = require("ai_tournament.supply_planner"),
        threatModel = require("ai_tournament.threat_model"),
        evaluator = evaluator
    }
    ctx.cache = cache.new(ctx)
    return ctx
end

local function findActionBySignature(ai, state, playerId, signature)
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local legal = ai:collectLegalActions(state, {
        aiPlayer = playerId,
        includeMove = true,
        includeAttack = true,
        includeRepair = true,
        includeDeploy = false
    }) or {}

    for _, entry in ipairs(legal) do
        if entry and entry.action and fixtureLib.actionSignature(entry.action) == signature then
            return entry.action
        end
    end
    return nil
end

runTest("score_own_fast_assigns_win_now_on_commandant_kill", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local evaluator = require("ai_tournament.evaluator")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local state = fixtureLib.buildBaseState({
        actingPlayer = 1,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 4, col = 6, currentHp = 1, startingHp = 12},
        units = {
            {
                name = "Crusher",
                player = 1,
                row = 4,
                col = 5,
                currentHp = 4,
                startingHp = 4,
                hasActed = false,
                hasMoved = false,
                actionsUsed = 0
            }
        }
    })

    local action = {
        type = "attack",
        unit = {row = 4, col = 5},
        target = {row = 4, col = 6}
    }

    local after = ai:deepCopyState(state)
    after.commandHubs[2].currentHp = 0
    local enemyHubUnit = ai:getUnitAtPosition(after, 4, 6)
    if enemyHubUnit then
        enemyHubUnit.currentHp = 0
    end
    assertTrue(evaluator.isCommandantDead(after, 2), "setup should produce enemy commandant kill")
    local candidate = {
        signature = "lethal_case",
        actions = {action},
        containsDeploy = false,
        tacticalTags = {}
    }
    local score = evaluator.scoreOwnTurnFast(ai, state, after, candidate, ctx)
    assertEquals(score.tier, ctx.score.TIER.WIN_NOW, "enemy commandant kill should be WIN_NOW")
end)

runTest("deploy_without_impact_is_not_rewarded", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local evaluator = require("ai_tournament.evaluator")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local state = fixtureLib.getFixture("healer_filler").state

    local deployments = ai:getPossibleSupplyDeploymentsForPlayer(state, 1, true, {
        scoreDeployments = false
    }) or {}

    local healerDeploy = nil
    for _, deploy in ipairs(deployments) do
        if deploy.unitName == "Healer" then
            healerDeploy = deploy
            break
        end
    end
    assertTrue(healerDeploy ~= nil, "expected healer deploy in fixture")

    local after = ai:applySupplyDeploymentForPlayer(state, healerDeploy, 1, {
        scoreDeployments = false
    })
    local candidate = {
        signature = "healer_filler",
        actions = {healerDeploy},
        containsDeploy = true,
        tacticalTags = {},
        buckets = {"supply_offense"}
    }

    local score = evaluator.scoreOwnTurnFast(ai, state, after, candidate, ctx)
    assertTrue((score.supply or 0) <= 0, "filler deploy should not receive positive supply score")
end)

runTest("bastion_block_deploy_receives_survival_or_supply_value", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local evaluator = require("ai_tournament.evaluator")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local state = fixtureLib.getFixture("supply_block_lethal").state

    local deployments = ai:getPossibleSupplyDeploymentsForPlayer(state, 1, true, {
        scoreDeployments = false
    }) or {}

    local bastionBlock = nil
    for _, deploy in ipairs(deployments) do
        if deploy.unitName == "Bastion" and deploy.target and deploy.target.row == 4 and deploy.target.col == 5 then
            bastionBlock = deploy
            break
        end
    end
    assertTrue(bastionBlock ~= nil, "expected Bastion block deploy")

    local after = ai:applySupplyDeploymentForPlayer(state, bastionBlock, 1, {
        scoreDeployments = false
    })
    local candidate = {
        signature = "bastion_block",
        actions = {bastionBlock},
        containsDeploy = true,
        tacticalTags = {preventsImmediateLoss = true},
        buckets = {"anti_lethal"}
    }

    local score = evaluator.scoreOwnTurnFast(ai, state, after, candidate, ctx)
    assertTrue((score.survival or 0) > 0 or (score.supply or 0) > 0, "defensive Bastion deploy should gain survival/supply value")
end)

runTest("score_contains_stable_breakdown_fields", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local evaluator = require("ai_tournament.evaluator")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local state = fixtureLib.getFixture("two_action_mandatory_continuation").state

    local action = findActionBySignature(ai, state, 1, "attack:4,4->4,5")
    assertTrue(action ~= nil, "expected attack action in fixture")
    local after = ai:simulateActionSequenceForPlayer(state, {action}, 1, {})

    local candidate = {
        signature = "breakdown_case",
        actions = {action},
        containsDeploy = false,
        tacticalTags = {},
        buckets = {"high_value_attack"}
    }

    local score = evaluator.scoreOwnTurnFast(ai, state, after, candidate, ctx)
    assertTrue(type(score.breakdown) == "table", "score breakdown should be table")
    assertTrue(type(score.breakdown.before) == "table", "breakdown.before missing")
    assertTrue(type(score.breakdown.after) == "table", "breakdown.after missing")
end)

runTest("higher_commandant_pressure_beats_quiet_material_tie", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local evaluator = require("ai_tournament.evaluator")
    local ai = mkAI(1)
    local ctx = newCtx(1)

    local state = fixtureLib.buildBaseState({
        actingPlayer = 1,
        playerOneHub = {name = "Commandant", player = 1, row = 2, col = 2, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 4, col = 8, currentHp = 12, startingHp = 12},
        units = {
            {
                name = "Wingstalker",
                player = 1,
                row = 4,
                col = 4,
                currentHp = 3,
                startingHp = 3,
                hasActed = false,
                hasMoved = false,
                actionsUsed = 0
            }
        }
    })

    local pressureAction = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 4, col = 5}
    }
    local quietAction = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 4, col = 3}
    }

    local afterPressure = ai:simulateActionSequenceForPlayer(state, {pressureAction}, 1, {})
    local afterQuiet = ai:simulateActionSequenceForPlayer(state, {quietAction}, 1, {})

    local pressureCandidate = {
        signature = "pressure_move",
        actions = {pressureAction},
        containsDeploy = false,
        tacticalTags = {commandantPressure = true},
        buckets = {"commandant_pressure"}
    }
    local quietCandidate = {
        signature = "quiet_move",
        actions = {quietAction},
        containsDeploy = false,
        tacticalTags = {},
        buckets = {"positional_move"}
    }

    local pressureScore = evaluator.scoreOwnTurnFast(ai, state, afterPressure, pressureCandidate, ctx)
    local quietScore = evaluator.scoreOwnTurnFast(ai, state, afterQuiet, quietCandidate, ctx)

    assertTrue(ctx.score.isBetter(pressureScore, quietScore), "pressure move should rank above quiet move in tie material state")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Evaluator Smoke"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "- Generated: " .. os.date("%Y-%m-%d %H:%M:%S")
    lines[#lines + 1] = "- Passed: " .. tostring(passCount)
    lines[#lines + 1] = "- Failed: " .. tostring(#results - passCount)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Results"
    lines[#lines + 1] = ""

    for _, result in ipairs(results) do
        local status = result.ok and "PASS" or "FAIL"
        lines[#lines + 1] = string.format("- `%s` %s (%.2fms)", status, result.name, result.ms)
        if not result.ok then
            lines[#lines + 1] = "  - Error: `" .. tostring(result.err):gsub("\n", " ") .. "`"
        end
    end

    return table.concat(lines, "\n")
end

local report = buildReport()
print(report)

local hasFailure = false
for _, result in ipairs(results) do
    if not result.ok then
        hasFailure = true
        break
    end
end

os.exit(hasFailure and 1 or 0)
