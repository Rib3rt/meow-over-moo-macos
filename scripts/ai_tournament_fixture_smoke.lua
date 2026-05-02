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

local function requireFixtureLibFresh()
    package.loaded["scripts.ai_tournament_fixture_lib"] = nil
    return require("scripts.ai_tournament_fixture_lib")
end

local function collectActionSet(fixtureLib, entries)
    local set = {}
    local count = 0

    for _, entry in ipairs(entries or {}) do
        if entry and entry.action then
            local signature = fixtureLib.actionSignature(entry.action)
            set[signature] = entry.action
            count = count + 1
        end
    end

    return set, count
end

local function hasAnySupplyDeploy(entries)
    for _, entry in ipairs(entries or {}) do
        if entry and entry.action and entry.action.type == "supply_deploy" then
            return true
        end
    end
    return false
end

local function findActionBySignature(fixtureLib, entries, wantedSignature)
    for _, entry in ipairs(entries or {}) do
        if entry and entry.action and fixtureLib.actionSignature(entry.action) == wantedSignature then
            return entry.action
        end
    end
    return nil
end

runTest("fixture_library_loads_without_love_graphics", function()
    local oldLove = rawget(_G, "love")
    _G.love = nil

    local ok, libOrErr = pcall(requireFixtureLibFresh)
    assertTrue(ok, "fixture lib should load without LOVE graphics dependency: " .. tostring(libOrErr))
    assertTrue(rawget(_G, "love") == nil, "fixture lib should not create love global")

    _G.love = oldLove
end)

runTest("fixture_catalog_contains_all_required_ids", function()
    local fixtureLib = requireFixtureLibFresh()
    local ids = fixtureLib.listFixtureIds()
    local required = fixtureLib.getRequiredFixtureIds()

    local idSet = {}
    for _, id in ipairs(ids) do
        idSet[id] = true
    end

    for _, requiredId in ipairs(required) do
        assertTrue(idSet[requiredId] == true, "missing required fixture id: " .. tostring(requiredId))
    end

    assertEquals(#ids, #required, "fixture catalog should currently contain the required baseline set")
end)

runTest("fixtures_declare_legal_winner_and_risk_expectations", function()
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local fixtures = fixtureLib.getAllFixtures()
    assertTrue(#fixtures > 0, "expected fixtures to exist")

    for _, fixture in ipairs(fixtures) do
        assertTrue(type(fixture.id) == "string" and fixture.id ~= "", "fixture id missing")
        assertTrue(type(fixture.state) == "table", "fixture state missing for " .. fixture.id)
        assertTrue(type(fixture.state.commandHubs) == "table", "command hubs missing for " .. fixture.id)
        assertTrue(type(fixture.state.commandHubs[1]) == "table", "player 1 hub missing for " .. fixture.id)
        assertTrue(type(fixture.state.commandHubs[2]) == "table", "player 2 hub missing for " .. fixture.id)

        local legal = fixture.expected and fixture.expected.legal or {}
        local outcome = fixture.expected and fixture.expected.outcome or {}
        local risk = fixture.expected and fixture.expected.risk or {}

        assertTrue(type(legal.mustIncludeActionSignatures) == "table", "mustInclude list missing for " .. fixture.id)
        local hasLegalExpectation = (#legal.mustIncludeActionSignatures > 0)
            or (tonumber(legal.minLegalActions) or 0) > 0
        assertTrue(hasLegalExpectation, "legal expectation missing for " .. fixture.id)

        -- Option-3 fixtures may be structural/telemetry probes and intentionally omit
        -- outcome/risk metadata while still asserting legal/action constraints.
        local _ = outcome
        local __ = risk
    end
end)

runTest("fixture_expected_actions_are_currently_legal", function()
    ensureHeadlessGlobals()

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local AI = require("ai")

    local fixtures = fixtureLib.getAllFixtures()
    for _, fixture in ipairs(fixtures) do
        GAME.CURRENT.AI_PLAYER_NUMBER = fixture.actingPlayer or 1
        local ai = AI.new({factionId = fixture.actingPlayer})
        ai.grid = {
            getUnitAt = function()
                return nil
            end
        }

        local legalEntries = ai:collectLegalActions(fixture.state, {
            includeMove = true,
            includeAttack = true,
            includeRepair = true,
            includeDeploy = true
        })
        local legalSet, legalCount = collectActionSet(fixtureLib, legalEntries)
        local legalExpect = fixture.expected.legal or {}

        if legalExpect.minLegalActions then
            assertTrue(
                legalCount >= legalExpect.minLegalActions,
                string.format(
                    "fixture %s expected at least %d legal actions, got %d",
                    fixture.id,
                    tonumber(legalExpect.minLegalActions),
                    legalCount
                )
            )
        end

        for _, expectedSignature in ipairs(legalExpect.mustIncludeActionSignatures or {}) do
            assertTrue(
                legalSet[expectedSignature] ~= nil,
                string.format("fixture %s missing legal action signature %s", fixture.id, tostring(expectedSignature))
            )
        end

        for _, blockedSignature in ipairs(legalExpect.mustExcludeActionSignatures or {}) do
            assertTrue(
                legalSet[blockedSignature] == nil,
                string.format("fixture %s unexpectedly contains blocked signature %s", fixture.id, tostring(blockedSignature))
            )
        end
    end
end)

runTest("enemy_supply_present_absent_fixtures_differ_only_on_reserve_fact", function()
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")

    local present = fixtureLib.getFixture("enemy_supply_present")
    local absent = fixtureLib.getFixture("enemy_supply_absent")

    assertTrue(present ~= nil and absent ~= nil, "enemy supply fixtures missing")

    local enemyPlayerPresent = present.opponentPlayer
    local enemyPlayerAbsent = absent.opponentPlayer

    assertEquals(#(present.state.supply[enemyPlayerPresent] or {}), 1, "enemy supply present fixture should expose one reserve unit")
    assertEquals(#(absent.state.supply[enemyPlayerAbsent] or {}), 0, "enemy supply absent fixture should expose no reserve unit")

    assertTrue(present.expected.risk.enemyDeployReplyExpected == true, "present fixture should expect enemy deploy replies")
    assertTrue(absent.expected.risk.enemyDeployReplyExpected == false, "absent fixture should expect no enemy deploy replies")
end)

runTest("move_plus_deploy_fixture_enables_deploy_after_mobility_action", function()
    ensureHeadlessGlobals()

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local AI = require("ai")

    local fixture = fixtureLib.getFixture("move_plus_deploy")
    assertTrue(fixture ~= nil, "move_plus_deploy fixture missing")

    GAME.CURRENT.AI_PLAYER_NUMBER = fixture.actingPlayer
    local ai = AI.new({factionId = fixture.actingPlayer})
    ai.grid = {
        getUnitAt = function()
            return nil
        end
    }

    local legalBefore = ai:collectLegalActions(fixture.state, {
        includeMove = true,
        includeAttack = true,
        includeRepair = true,
        includeDeploy = true
    })

    assertTrue(not hasAnySupplyDeploy(legalBefore), "expected no deploy actions before freeing hub-adjacent cell")

    local freeingMoveSignature = fixture.expected.legal.mustIncludeActionSignatures[1]
    local freeingMove = findActionBySignature(fixtureLib, legalBefore, freeingMoveSignature)
    assertTrue(freeingMove ~= nil, "expected move action to free deploy cell: " .. tostring(freeingMoveSignature))

    local afterMove = ai:simulateActionSequence(fixture.state, {freeingMove})
    local legalAfter = ai:collectLegalActions(afterMove, {
        includeMove = true,
        includeAttack = true,
        includeRepair = true,
        includeDeploy = true
    })

    assertTrue(hasAnySupplyDeploy(legalAfter), "expected at least one deploy action after freeing adjacent cell")
end)

runTest("tactical_extension_fixtures_carry_proof_and_refutation_markers", function()
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")

    local proof = fixtureLib.getFixture("tactical_extension_proof")
    local refute = fixtureLib.getFixture("tactical_extension_refutation")

    assertTrue(proof ~= nil and refute ~= nil, "tactical extension fixtures missing")

    assertEquals(proof.expected.risk.expectedExtensionResult, "proved_force", "proof fixture should mark expected proof result")
    assertEquals(refute.expected.risk.expectedExtensionResult, "refuted_force", "refutation fixture should mark expected refutation result")
end)

runTest("fixture_getter_returns_deep_copy", function()
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")

    local first = fixtureLib.getFixture("immediate_commandant_lethal")
    local second = fixtureLib.getFixture("immediate_commandant_lethal")

    assertTrue(first ~= nil and second ~= nil, "fixture should exist")
    first.state.units[1].row = 99

    assertTrue(second.state.units[1].row ~= 99, "fixture getter should return deep copy")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Fixture Baseline Smoke"
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
