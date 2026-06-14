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

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local clone = {}
    seen[value] = clone
    for key, child in pairs(value) do
        clone[deepCopy(key, seen)] = deepCopy(child, seen)
    end

    return clone
end

local function mkAI(factionId, reference)
    local AI = require("ai")
    local ai = AI.new({factionId = factionId})
    ai.grid = {
        getUnitAt = function()
            return nil
        end
    }
    if reference then
        ai:setAiReference(reference, "latency_smoke")
    end
    return ai
end

local function withTournamentOverrides(ai, overrides, fn)
    local cfg = ai.AI_PARAMS.TOURNAMENT_AI
    local backup = {}
    for key, _ in pairs(overrides or {}) do
        backup[key] = cfg[key]
    end

    for key, value in pairs(overrides or {}) do
        cfg[key] = value
    end

    local ok, r1, r2, r3 = xpcall(fn, debug.traceback)

    for key, value in pairs(backup) do
        cfg[key] = value
    end

    if not ok then
        error(r1, 0)
    end

    return r1, r2, r3
end

local function percentile(values, ratio)
    if #values == 0 then
        return 0
    end

    local sorted = {}
    for i = 1, #values do
        sorted[i] = values[i]
    end
    table.sort(sorted)
    local index = math.max(1, math.ceil(#sorted * ratio))
    return sorted[index] or sorted[#sorted]
end

local function scoreSignature(score)
    if type(score) ~= "table" then
        return "none"
    end

    return table.concat({
        tostring(score.tier or "nil"),
        tostring(score.terminal or 0),
        tostring(score.survival or 0),
        tostring(score.force or 0),
        tostring(score.commandant or 0),
        tostring(score.material or 0),
        tostring(score.supply or 0),
        tostring(score.position or 0),
        tostring(score.risk or 0),
        tostring(score.efficiency or 0),
        tostring(score.signature or "")
    }, "|")
end

local function assertValidSequence(sequence, message)
    assertTrue(type(sequence) == "table" and #sequence > 0, message or "expected non-empty sequence")
    for index, action in ipairs(sequence) do
        assertTrue(type(action) == "table", string.format("action %d should be a table", index))
        assertTrue(type(action.type) == "string" and action.type ~= "", string.format("action %d should have type", index))
    end
end

local function buildManyUnitsState(fixtureLib)
    return fixtureLib.buildBaseState({
        actingPlayer = 1,
        turnNumber = 18,
        currentTurn = 18,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 7, currentHp = 12, startingHp = 12},
        units = {
            {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Crusher", player = 1, row = 3, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Bastion", player = 1, row = 4, col = 2, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Artillery", player = 1, row = 2, col = 4, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Cloudstriker", player = 1, row = 4, col = 5, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Earthstalker", player = 1, row = 3, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0},

            {name = "Wingstalker", player = 2, row = 7, col = 7, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Crusher", player = 2, row = 6, col = 7, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Bastion", player = 2, row = 5, col = 7, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Artillery", player = 2, row = 7, col = 5, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Cloudstriker", player = 2, row = 5, col = 4, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Earthstalker", player = 2, row = 6, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0}
        },
        supplyOne = {
            {name = "Bastion", currentHp = 6, startingHp = 6},
            {name = "Cloudstriker", currentHp = 4, startingHp = 4}
        },
        supplyTwo = {
            {name = "Bastion", currentHp = 6, startingHp = 6},
            {name = "Healer", currentHp = 4, startingHp = 4}
        }
    })
end

runTest("determinism_same_state_same_sequence_score_and_reply_signature", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local fixture = fixtureLib.getFixture("deploy_plus_attack")

    local expectedSequenceSig = nil
    local expectedScoreSig = nil
    local expectedWorstReplySig = nil

    for iteration = 1, 20 do
        GAME.CURRENT.TURN = 100 + iteration
        local ai = mkAI(1, "base")

        withTournamentOverrides(ai, {
            ENABLED = true,
            LOG_SUMMARY = false
        }, function()
            local state = deepCopy(fixture.state)
            local sequence = ai:getBestSequence(state)
            assertValidSequence(sequence, "Tournament should return valid deterministic sequence")

            local meta = ai.lastTournamentMeta or {}
            local selected = meta.selected or {}
            local reply = selected.reply or {}
            local summary = reply.summary or {}
            local sequenceSig = ai:buildActionSequenceSignature(sequence)
            local scoreSig = scoreSignature(selected.finalScore or selected.fastScore)
            local worstReplySig = tostring(summary.signature or "none")

            if not expectedSequenceSig then
                expectedSequenceSig = sequenceSig
                expectedScoreSig = scoreSig
                expectedWorstReplySig = worstReplySig
            else
                assertEquals(sequenceSig, expectedSequenceSig, "sequence signature should be deterministic")
                assertEquals(scoreSig, expectedScoreSig, "final score tuple should be deterministic")
                assertEquals(worstReplySig, expectedWorstReplySig, "worst reply signature should be deterministic")
            end
        end)
    end
end)

runTest("complete_turn_enforcement_avoids_skip_and_sanitizer_replacements", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local fixture = fixtureLib.getFixture("two_action_mandatory_continuation")
    local ai = mkAI(1, "base")

    withTournamentOverrides(ai, {
        ENABLED = true,
        LOG_SUMMARY = false
    }, function()
        local state = deepCopy(fixture.state)
        local sequence = ai:getBestSequence(state)
        local meta = ai.lastTournamentMeta or {}
        local sanitize = ai._lastSanitizeSummary or {}

        assertEquals(#sequence, 2, "selected sequence must contain two actions in non-terminal complete-turn fixture")
        assertTrue(sequence[1].type ~= "skip" and sequence[2].type ~= "skip", "skip should be absent when legal non-skip actions exist")
        assertEquals(sanitize.replacements or 0, 0, "selected Tournament sequence should not need sanitizer replacements")
        assertTrue(meta.reason ~= "immediate_win", "fixture should not be resolved as immediate terminal win")
    end)
end)

runTest("latency_p95_respects_budget_on_representative_states", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")

    local states = {
        {label = "opening", build = function()
            return fixtureLib.buildBaseState({
                actingPlayer = 1,
                turnNumber = 1,
                currentTurn = 1,
                playerOneHub = {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 12, startingHp = 12},
                playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 7, currentHp = 12, startingHp = 12},
                units = {
                    {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0},
                    {name = "Wingstalker", player = 2, row = 7, col = 7, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0}
                },
                supplyOne = {
                    {name = "Bastion", currentHp = 6, startingHp = 6},
                    {name = "Cloudstriker", currentHp = 4, startingHp = 4}
                },
                supplyTwo = {
                    {name = "Bastion", currentHp = 6, startingHp = 6},
                    {name = "Cloudstriker", currentHp = 4, startingHp = 4}
                }
            })
        end},
        {label = "midgame_with_supply", build = function() return fixtureLib.getFixture("deploy_plus_attack").state end},
        {label = "midgame_without_supply", build = function() return fixtureLib.getFixture("two_action_mandatory_continuation").state end},
        {label = "threatened_commandant", build = function() return fixtureLib.getFixture("immediate_commandant_defense").state end},
        {label = "many_units", build = function() return buildManyUnitsState(fixtureLib) end}
    }

    local latencies = {}
    local repetitionsPerState = 3

    for _, entry in ipairs(states) do
        for repeatIndex = 1, repetitionsPerState do
            GAME.CURRENT.TURN = GAME.CURRENT.TURN + 1
            local ai = mkAI(1, "base")

            withTournamentOverrides(ai, {
                ENABLED = true,
                LOG_SUMMARY = false
            }, function()
                local state = deepCopy(entry.build())
                local startedAt = os.clock()
                local sequence = ai:getBestSequence(state)
                local elapsedMs = (os.clock() - startedAt) * 1000
                latencies[#latencies + 1] = elapsedMs
                assertValidSequence(sequence, "Tournament should return valid sequence for representative state: " .. entry.label)
            end)
        end
    end

    local sampleAI = mkAI(1, "base")
    local hardBudget = sampleAI:getTournamentBudgetMs("HARD_BUDGET_MS", 500)
    local scheduler = (sampleAI.AI_PARAMS and sampleAI.AI_PARAMS.SCHEDULER) or {}
    local asyncBudget = scheduler.AI_DECISION_ASYNC_ENABLED == true
        and tonumber(scheduler.AI_DECISION_ASYNC_HARD_BUDGET_MS)
        or nil
    local effectiveBudget = asyncBudget or hardBudget
    local tolerance = asyncBudget and 180 or 120
    local p95 = percentile(latencies, 0.95)

    assertTrue(
        p95 <= (effectiveBudget + tolerance),
        string.format(
            "p95 compute %.2fms exceeds quality budget guard (%dms + tolerance)",
            p95,
            effectiveBudget
        )
    )
end)

runTest("hard_timeout_returns_best_valid_candidate", function()
    ensureHeadlessGlobals()

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local brain = require("ai_tournament.brain")
    local fixture = fixtureLib.getFixture("two_action_mandatory_continuation")
    local ai = mkAI(1, "base")

    withTournamentOverrides(ai, {
        ENABLED = true,
        RETURN_BEST_ON_TIMEOUT = true,
        LOG_SUMMARY = false
    }, function()
        local sequence, meta = brain.chooseTurn(ai, deepCopy(fixture.state), {
            maxActions = 2,
            decisionStartTime = love.timer.getTime() - 2.0
        })
        assertTrue(type(meta) == "table", "brain should always return meta")
        assertTrue(type(sequence) == "table" and #sequence > 0, "timeout must still return Tournament-owned sequence")
        local reason = tostring(meta.reason or "")
        local fallbackSource = tostring(((meta.stats or {}).fallbackSource) or "none")
        assertTrue(
            reason == "best_before_timeout"
                or reason == "best_fast_fallback"
                or reason == "selected"
                or reason:find("pipeline_v2_", 1, true) == 1
                or reason:find("hard_", 1, true) == 1,
            "timeout reason must remain Tournament/V2-owned"
        )
        assertTrue(
            fallbackSource:find("legacy", 1, true) == nil,
            "timeout path must not use removed legacy fallback"
        )
        assertValidSequence(sequence, "timeout path should return a valid Tournament sequence")
    end)
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Latency/Determinism Smoke"
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
