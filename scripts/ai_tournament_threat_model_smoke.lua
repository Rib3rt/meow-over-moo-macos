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
    if not hub then
        return true
    end
    local hp = hub.currentHp or hub.startingHp or 0
    if hp <= 0 then
        return true
    end
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.player == playerId and unit.name == "Commandant" then
            return (unit.currentHp or unit.startingHp or 0) <= 0
        end
    end
    return false
end

local function newCtx(ai)
    local cache = require("ai_tournament.cache")
    local ctx = {
        cfg = ai:getTournamentConfig(),
        stats = {},
        threatModel = require("ai_tournament.threat_model"),
        turnEnumerator = require("ai_tournament.turn_enumerator"),
        supplyPlanner = require("ai_tournament.supply_planner"),
        candidateBuckets = require("ai_tournament.candidate_buckets"),
        evaluator = {
            isCommandantDead = isCommandantDead
        }
    }
    ctx.cache = cache.new(ctx)
    return ctx
end

local function unit(name, player, row, col, hp, maxHp)
    return {
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = hp,
        startingHp = maxHp or hp,
        hasActed = false,
        hasMoved = false,
        actionsUsed = 0
    }
end

runTest("threat_model_is_player_aware_and_stable_against_ai_faction", function()
    ensureHeadlessGlobals()

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local threatModel = require("ai_tournament.threat_model")
    local fixture = fixtureLib.getFixture("immediate_commandant_defense")
    local state = fixture.state
    local ai = mkAI(1)

    local first = threatModel.analyzeHubThreatForPlayer(ai, state, 1, 2, {})
    ai.factionId = 2
    local second = threatModel.analyzeHubThreatForPlayer(ai, state, 1, 2, {})

    assertEquals(first.immediateLethal, second.immediateLethal, "threat analysis must be stable across ai.factionId changes")
    assertEquals(first.projectedDamage, second.projectedDamage, "projected damage must remain stable")
    assertEquals(#(first.damagingAttackers or {}), #(second.damagingAttackers or {}), "attacker count must remain stable")

    assertTrue(#(first.damagingAttackers or {}) > 0, "fixture should contain attackers")
    for _, entry in ipairs(first.damagingAttackers or {}) do
        assertEquals(entry.unit and entry.unit.player, 2, "threat to player 1 must only list player 2 attackers")
    end
end)

runTest("move_attack_commandant_pressure_is_detected_before_lethal", function()
    ensureHeadlessGlobals()

    local threatModel = require("ai_tournament.threat_model")
    local ai = mkAI(1)
    local state = {
        gridSize = 8,
        currentTurn = 12,
        commandHubs = {
            [1] = {row = 1, col = 4, currentHp = 4, startingHp = 12},
            [2] = {row = 7, col = 4, currentHp = 12, startingHp = 12}
        },
        units = {
            unit("Commandant", 1, 1, 4, 4, 12),
            unit("Commandant", 2, 7, 4, 12, 12),
            unit("Cloudstriker", 1, 2, 4, 3, 4),
            unit("Artillery", 2, 5, 4, 5, 5)
        },
        unitsWithRemainingActions = {},
        supply = {[1] = {}, [2] = {}},
        neutralBuildings = {},
        attackedObjectivesThisTurn = {}
    }

    local result = threatModel.analyzeHubThreatForPlayer(ai, state, 1, 2, newCtx(ai))

    assertTrue(result.immediateLethal == false, "pressure is non-lethal at 4 HP")
    assertTrue(result.immediateDanger == true, "move+attack pressure should activate commandant danger")
    assertTrue(result.fullTurnPressure == true, "pressure should be marked as full-turn move+attack")
    assertEquals(result.projectedDamage, 2, "Artillery move+attack should project 2 commandant damage")
    assertEquals(result.damagingAttackers[1].unit.row, 5, "threat target should keep current attacker row")
    assertEquals(result.damagingAttackers[1].unit.col, 4, "threat target should keep current attacker col")
    assertEquals(result.damagingAttackers[1].projectedUnit.row, 4, "projected attack row should be recorded")
    assertEquals(result.damagingAttackers[1].projectedUnit.col, 4, "projected attack col should be recorded")
end)

runTest("threat_model_for_enemy_perspective_never_lists_self_attackers", function()
    ensureHeadlessGlobals()

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local threatModel = require("ai_tournament.threat_model")
    local fixture = fixtureLib.getFixture("immediate_commandant_lethal")
    local state = fixture.state
    local ai = mkAI(1)

    local threatToEnemy = threatModel.analyzeHubThreatForPlayer(ai, state, 2, 1, {})
    assertTrue(threatToEnemy.immediateDanger == true, "enemy hub should be under immediate danger in lethal fixture")
    for _, entry in ipairs(threatToEnemy.damagingAttackers or {}) do
        assertEquals(entry.unit and entry.unit.player, 1, "threat to player 2 must only list player 1 attackers")
    end

    local threatToSelf = threatModel.analyzeHubThreatForPlayer(ai, state, 1, 2, {})
    for _, entry in ipairs(threatToSelf.damagingAttackers or {}) do
        assertEquals(entry.unit and entry.unit.player, 2, "threat to player 1 must only list player 2 attackers")
    end
end)

runTest("immediate_lethal_matches_complete_turn_enumerator", function()
    ensureHeadlessGlobals()

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local threatModel = require("ai_tournament.threat_model")
    local fixture = fixtureLib.getFixture("immediate_commandant_lethal")
    local state = fixture.state
    local ai = mkAI(1)
    local ctx = newCtx(ai)

    local lethal, lethalSequence = threatModel.hasImmediateCommandantLethal(ai, state, 1, 2, ctx)
    assertTrue(lethal == true, "threat model should detect immediate lethal")
    assertTrue(type(lethalSequence) == "table" and #lethalSequence > 0, "threat model should return an explicit lethal line")

    local candidates = ctx.turnEnumerator.generateFullTurnCandidates(ai, state, 1, ctx, {
        maxCandidates = 120
    })

    local foundTerminal = false
    for _, candidate in ipairs(candidates or {}) do
        local after = ai:simulateActionSequenceForPlayer(state, candidate.actions, 1, {})
        if ctx.evaluator.isCommandantDead(after, 2) then
            foundTerminal = true
            break
        end
    end

    assertTrue(foundTerminal, "complete-turn enumerator should include at least one terminal lethal line")
end)

runTest("threat_cache_key_depends_on_explicit_players", function()
    ensureHeadlessGlobals()

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local threatModel = require("ai_tournament.threat_model")
    local fixture = fixtureLib.getFixture("deploy_plus_attack")
    local state = fixture.state

    local sigA = threatModel.signature(state, 1, 2)
    local sigB = threatModel.signature(state, 2, 1)
    assertTrue(sigA ~= sigB, "threat signature must encode explicit protect/attacker players")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Threat Model Smoke"
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
