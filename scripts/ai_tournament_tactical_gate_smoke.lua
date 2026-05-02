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
    local ctx = {
        cfg = {
            MAX_FIRST_ACTIONS = 72,
            MAX_SECOND_ACTIONS = 36,
            MAX_OWN_CANDIDATES = 320,
            MAX_ENEMY_REPLY_CANDIDATES = 20
        },
        aiPlayer = aiPlayer,
        enemyPlayer = aiPlayer == 1 and 2 or 1,
        score = score,
        evaluator = evaluator,
        turnEnumerator = turnEnumerator,
        candidateBuckets = require("ai_tournament.candidate_buckets"),
        supplyPlanner = require("ai_tournament.supply_planner"),
        reserveModel = require("ai_tournament.reserve_model"),
        threatModel = require("ai_tournament.threat_model"),
        tacticalGate = require("ai_tournament.tactical_gate"),
        stats = {}
    }
    ctx.cache = cache.new(ctx)
    function ctx.shouldStop()
        return false
    end
    return ctx
end

local function candidateHasDeployAt(candidate, unitName, row, col)
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action
            and action.type == "supply_deploy"
            and action.unitName == unitName
            and action.target
            and action.target.row == row
            and action.target.col == col then
            return true
        end
    end
    return false
end

local function candidateHitsHub(candidate, hub)
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action and action.type == "attack" and action.target and action.target.row == hub.row and action.target.col == hub.col then
            return true
        end
    end
    return false
end

runTest("tactical_gate_finds_immediate_win", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local ai = mkAI(1)
    local ctx = newCtx(1)
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

    local immediate = ctx.tacticalGate.findImmediateWin(ai, state, ctx)
    assertTrue(immediate ~= nil and immediate.candidate ~= nil, "expected immediate win candidate")

    local after = ai:simulateActionSequenceForPlayer(state, immediate.candidate.actions, 1, {})
    assertTrue(ctx.evaluator.isCommandantDead(after, 2), "immediate win candidate should kill enemy commandant")
end)

runTest("forced_response_filter_removes_losing_lines_when_defense_exists", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local state = fixtureLib.getFixture("supply_block_lethal").state

    local threat = ctx.tacticalGate.detectImmediateThreat(ai, state, 1, 2, ctx)
    assertTrue(threat and threat.immediateLethal == true, "fixture should produce immediate lethal threat")

    local candidates = ctx.turnEnumerator.generateFullTurnCandidates(ai, state, 1, ctx, {})
    assertTrue(#candidates > 0, "expected candidate pool before forced filter")

    local filtered, meta = ctx.tacticalGate.filterForcedResponses(ai, state, candidates, threat, ctx)
    assertTrue(meta and meta.forced == true, "forced-response metadata should mark forced state")
    assertTrue(#filtered > 0, "expected at least one candidate after forced filtering")

    for _, candidate in ipairs(filtered) do
        local after = ai:simulateActionSequenceForPlayer(state, candidate.actions, 1, {})
        local enemyThreat = ctx.tacticalGate.detectImmediateThreat(ai, after, 1, 2, ctx)
        assertTrue(enemyThreat.immediateLethal ~= true, "filtered candidate should prevent immediate loss")
    end
end)

runTest("supply_block_candidate_survives_forced_filter", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local state = fixtureLib.getFixture("supply_block_lethal").state

    local threat = ctx.tacticalGate.detectImmediateThreat(ai, state, 1, 2, ctx)
    local candidates = ctx.turnEnumerator.generateFullTurnCandidates(ai, state, 1, ctx, {})
    local filtered = select(1, ctx.tacticalGate.filterForcedResponses(ai, state, candidates, threat, ctx))

    local foundBlock = false
    for _, candidate in ipairs(filtered or {}) do
        if candidateHasDeployAt(candidate, "Bastion", 4, 5) then
            foundBlock = true
            break
        end
    end

    assertTrue(foundBlock, "expected Bastion block deploy to survive forced filter")
end)

runTest("forcing_pressure_candidate_is_marked_for_tactical_extension", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local state = fixtureLib.getFixture("tactical_extension_proof").state
    local enemyHub = state.commandHubs and state.commandHubs[2]

    local candidates = ctx.turnEnumerator.generateFullTurnCandidates(ai, state, 1, ctx, {
        mode = "punish_commandant"
    })
    assertTrue(#candidates > 0, "expected forcing candidates")

    local pressure = nil
    for _, candidate in ipairs(candidates) do
        if candidateHitsHub(candidate, enemyHub) then
            pressure = candidate
            break
        end
    end
    assertTrue(pressure ~= nil, "expected candidate that hits enemy commandant")

    local annotated = ctx.tacticalGate.annotateCandidate(ai, state, pressure, ctx)
    assertTrue(ctx.tacticalGate.needsTacticalExtension(ai, state, annotated, ctx), "forcing pressure candidate should request tactical extension")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Tactical Gate Smoke"
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
