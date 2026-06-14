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

local function isCommandantDead(state, playerId)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if hub and (hub.currentHp or hub.startingHp or 1) <= 0 then
        return true
    end
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.player == playerId and unit.name == "Commandant" then
            return (unit.currentHp or unit.startingHp or 1) <= 0
        end
    end
    return false
end

local function newCtx()
    local turnEnumerator = require("ai_tournament.turn_enumerator")
    local cache = require("ai_tournament.cache")
    local ctx = {
        cfg = {
            MAX_FIRST_ACTIONS = 72,
            MAX_SECOND_ACTIONS = 36,
            MAX_OWN_CANDIDATES = 320,
            MAX_DEPLOY_ACTIONS_PER_STATE = 24
        },
        stats = {},
        supplyPlanner = require("ai_tournament.supply_planner"),
        candidateBuckets = require("ai_tournament.candidate_buckets"),
        threatModel = require("ai_tournament.threat_model"),
        turnEnumerator = turnEnumerator,
        evaluator = {
            isCommandantDead = isCommandantDead
        }
    }
    ctx.cache = cache.new(ctx)
    return ctx
end

local function candidateHasPattern(candidate, firstType, secondType)
    local a1 = candidate and candidate.actions and candidate.actions[1]
    local a2 = candidate and candidate.actions and candidate.actions[2]
    return a1 and a2 and a1.type == firstType and a2.type == secondType
end

runTest("enumerator_generates_complete_unique_candidates", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local turnEnumerator = require("ai_tournament.turn_enumerator")
    local ai = mkAI(1)
    local fixture = fixtureLib.getFixture("two_action_mandatory_continuation")
    local state = fixture.state
    local ctx = newCtx()

    local candidates = turnEnumerator.generateFullTurnCandidates(ai, state, 1, ctx, {})
    assertTrue(#candidates > 0, "expected at least one full-turn candidate")

    local seen = {}
    for _, candidate in ipairs(candidates) do
        assertTrue(candidate.signature ~= nil and candidate.signature ~= "", "candidate signature missing")
        assertTrue(not seen[candidate.signature], "duplicate candidate signature: " .. tostring(candidate.signature))
        seen[candidate.signature] = true

        local simulated = ai:simulateActionSequenceForPlayer(state, candidate.actions, 1, {})
        assertTrue(simulated ~= nil, "candidate sequence failed simulation")

        assertTrue(candidate.completeTurn == true, "final candidate should be marked completeTurn")
        assertEquals(#(candidate.actions or {}), 2, "fixture requires full two-action turn candidates")

        local deployCount = 0
        for _, action in ipairs(candidate.actions or {}) do
            if action and action.type == "supply_deploy" then
                deployCount = deployCount + 1
            end
        end
        assertTrue(deployCount <= 1, "candidate must not include two deploy actions")
    end
end)

runTest("enumerator_includes_move_plus_deploy_pattern_when_legal", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local turnEnumerator = require("ai_tournament.turn_enumerator")
    local ai = mkAI(1)
    local fixture = fixtureLib.getFixture("move_plus_deploy")
    local state = fixture.state
    local ctx = newCtx()

    local candidates = turnEnumerator.generateFullTurnCandidates(ai, state, 1, ctx, {})
    local found = false
    for _, candidate in ipairs(candidates) do
        if candidateHasPattern(candidate, "move", "supply_deploy") then
            found = true
            break
        end
    end

    assertTrue(found, "expected at least one move+deploy candidate")
end)

runTest("enumerator_includes_deploy_plus_attack_pattern_when_legal", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local turnEnumerator = require("ai_tournament.turn_enumerator")
    local ai = mkAI(1)
    local fixture = fixtureLib.getFixture("deploy_plus_attack")
    local state = fixture.state
    local ctx = newCtx()

    local candidates = turnEnumerator.generateFullTurnCandidates(ai, state, 1, ctx, {})
    local found = false
    for _, candidate in ipairs(candidates) do
        if candidateHasPattern(candidate, "supply_deploy", "attack") then
            found = true
            break
        end
    end

    assertTrue(found, "expected at least one deploy+attack candidate")
end)

runTest("enumerator_is_deterministic_for_same_state", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local turnEnumerator = require("ai_tournament.turn_enumerator")
    local ai = mkAI(1)
    local fixture = fixtureLib.getFixture("deploy_plus_attack")
    local state = fixture.state

    local ctxA = newCtx()
    local ctxB = newCtx()

    local first = turnEnumerator.generateFullTurnCandidates(ai, state, 1, ctxA, {})
    local second = turnEnumerator.generateFullTurnCandidates(ai, state, 1, ctxB, {})

    assertEquals(#first, #second, "determinism candidate count mismatch")
    for index = 1, #first do
        assertEquals(first[index].signature, second[index].signature, "determinism signature mismatch at index " .. tostring(index))
    end
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Enumerator Smoke"
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
