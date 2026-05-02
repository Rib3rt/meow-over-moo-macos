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
    local turnEnumerator = require("ai_tournament.turn_enumerator")
    local evaluator = require("ai_tournament.evaluator")
    local responseModel = require("ai_tournament.response_model")
    local tacticalGate = require("ai_tournament.tactical_gate")
    local tacticalExtension = require("ai_tournament.tactical_extension")

    local ctx = {
        cfg = {
            USE_ENEMY_REPLY = true,
            MAX_FIRST_ACTIONS = 72,
            MAX_SECOND_ACTIONS = 36,
            MAX_OWN_CANDIDATES = 320,
            MAX_ENEMY_REPLY_CANDIDATES = 20,
            MAX_TACTICAL_EXTENSION_FINALISTS = 12,
            MAX_TACTICAL_EXTENSIONS = 24
        },
        aiPlayer = aiPlayer,
        enemyPlayer = aiPlayer == 1 and 2 or 1,
        score = score,
        evaluator = evaluator,
        turnEnumerator = turnEnumerator,
        responseModel = responseModel,
        tacticalGate = tacticalGate,
        tacticalExtension = tacticalExtension,
        candidateBuckets = require("ai_tournament.candidate_buckets"),
        supplyPlanner = require("ai_tournament.supply_planner"),
        reserveModel = require("ai_tournament.reserve_model"),
        threatModel = require("ai_tournament.threat_model"),
        stats = {}
    }

    ctx.cache = cache.new(ctx)
    function ctx.elapsedMs()
        return 0
    end
    function ctx.hardStop()
        return false
    end
    function ctx.shouldStop()
        return false
    end

    return ctx
end

local function candidateHitsEnemyHub(candidate, hub)
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action and action.type == "attack" and action.target and action.target.row == hub.row and action.target.col == hub.col then
            return true
        end
    end
    return false
end

local function pickPressureCandidate(ai, state, ctx)
    local hub = state.commandHubs and state.commandHubs[ctx.enemyPlayer]
    local candidates = ctx.turnEnumerator.generateFullTurnCandidates(ai, state, ctx.aiPlayer, ctx, {
        mode = "punish_commandant",
        maxCandidates = 64
    })
    for _, candidate in ipairs(candidates or {}) do
        if candidateHitsEnemyHub(candidate, hub) then
            return candidate
        end
    end
    return candidates and candidates[1] or nil
end

runTest("extension_proves_real_force_on_proof_fixture", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local state = fixtureLib.getFixture("tactical_extension_proof").state

    local candidate = pickPressureCandidate(ai, state, ctx)
    assertTrue(candidate ~= nil, "expected forcing candidate for proof fixture")

    local afterOur = ctx.cache.simulate(ai, state, candidate.actions, 1, ctx)
    local reply = ctx.responseModel.evaluateWorstReply(ai, afterOur, ctx)
    local ext = ctx.tacticalExtension.evaluateFinalist(ai, state, afterOur, reply, candidate, ctx)

    assertTrue(
        ext.result == "proved_force" or (ext.forceDelta or 0) > 0 or ext.tierUpgrade == ctx.score.TIER.FORCE_WIN_NEXT,
        "proof fixture should produce a proven force extension signal"
    )
end)

runTest("extension_refutes_fake_pressure_on_refutation_fixture", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local state = fixtureLib.getFixture("tactical_extension_refutation").state

    local candidate = pickPressureCandidate(ai, state, ctx)
    assertTrue(candidate ~= nil, "expected forcing candidate for refutation fixture")

    local afterOur = ctx.cache.simulate(ai, state, candidate.actions, 1, ctx)
    local reply = ctx.responseModel.evaluateWorstReply(ai, afterOur, ctx)
    local ext = ctx.tacticalExtension.evaluateFinalist(ai, state, afterOur, reply, candidate, ctx)

    assertTrue(
        ext.result == "refuted_force" or (ext.forceDelta or 0) < 0 or ext.tierDowngrade ~= nil,
        "refutation fixture should downgrade fake pressure"
    )
end)

runTest("reply_continuation_reports_harm", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local beforeEnemy = fixtureLib.buildBaseState({
        actingPlayer = 2,
        playerOneHub = {name = "Commandant", player = 1, row = 4, col = 4, currentHp = 3, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            {
                name = "Crusher",
                player = 2,
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

    local enemyAction = {
        type = "attack",
        unit = {row = 4, col = 5},
        target = {row = 4, col = 4}
    }
    local afterEnemy = ai:simulateActionSequenceForPlayer(beforeEnemy, {enemyAction}, 2, {})
    local extReply = ctx.tacticalExtension.evaluateReplyContinuation(ai, beforeEnemy, afterEnemy, {
        signature = "enemy_kill",
        actions = {enemyAction}
    }, ctx)

    assertTrue((extReply.harmToUs or 0) > 0, "reply continuation should report positive harm")
end)

runTest("extension_returns_timeout_when_hard_budget_fires", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local state = fixtureLib.getFixture("tactical_extension_proof").state
    ctx.hardStop = function()
        return true
    end

    local candidate = pickPressureCandidate(ai, state, ctx)
    assertTrue(candidate ~= nil, "expected forcing candidate")
    local afterOur = ctx.cache.simulate(ai, state, candidate.actions, 1, ctx)
    local ext = ctx.tacticalExtension.evaluateFinalist(ai, state, afterOur, {afterEnemy = nil}, candidate, ctx)
    assertTrue(ext.result == "timeout", "hard-stop budget should force timeout extension result")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Tactical Extension Smoke"
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
