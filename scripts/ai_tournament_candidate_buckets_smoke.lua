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

local function pickActionBySignature(ai, state, playerId, signature)
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

local function containsSignature(entries, signature)
    for _, entry in ipairs(entries or {}) do
        if entry and entry.signature == signature then
            return true
        end
    end
    return false
end

runTest("lethal_attack_is_classified_as_lethal_bucket", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local candidateBuckets = require("ai_tournament.candidate_buckets")
    local ai = mkAI(1)
    local fixture = fixtureLib.getFixture("immediate_commandant_lethal")
    local state = fixture.state

    local lethalAction = pickActionBySignature(ai, state, 1, "attack:4,5->4,6")
    assertTrue(lethalAction ~= nil, "expected lethal action in fixture legal actions")

    local classified = candidateBuckets.classifyAction(ai, state, lethalAction, 1, {})
    assertEquals(classified.bucket, "lethal", "lethal fixture attack must classify as lethal")
end)

runTest("defensive_bastion_deploy_is_preserved_as_defense_bucket", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local candidateBuckets = require("ai_tournament.candidate_buckets")
    local supplyPlanner = require("ai_tournament.supply_planner")
    local ai = mkAI(1)
    local fixture = fixtureLib.getFixture("supply_block_lethal")
    local state = fixture.state

    local ctx = {
        cfg = {},
        threatModel = require("ai_tournament.threat_model")
    }

    local deployEntries = supplyPlanner.getDeployActionEntries(ai, state, 1, ctx)
    local defensiveDeploy = nil
    for _, entry in ipairs(deployEntries or {}) do
        local action = entry.action or {}
        local target = action.target or {}
        if action.unitName == "Bastion" and target.row == 4 and target.col == 5 then
            defensiveDeploy = entry
            break
        end
    end

    assertTrue(defensiveDeploy ~= nil, "expected Bastion blocking deploy entry at 4,5")

    local classified = candidateBuckets.classifyAction(ai, state, defensiveDeploy.action, 1, ctx, {
        entry = defensiveDeploy
    })

    assertTrue(
        classified.bucket == "anti_lethal" or classified.bucket == "supply_defense",
        "defensive Bastion deploy must classify as anti_lethal or supply_defense"
    )
end)

runTest("cloudstriker_lane_deploy_is_classified_as_supply_offense", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local candidateBuckets = require("ai_tournament.candidate_buckets")
    local supplyPlanner = require("ai_tournament.supply_planner")
    local ai = mkAI(1)

    local state = fixtureLib.buildBaseState({
        actingPlayer = 1,
        playerOneHub = {name = "Commandant", player = 1, row = 4, col = 4, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 4, col = 8, currentHp = 12, startingHp = 12},
        units = {},
        supplyOne = {
            {name = "Cloudstriker", currentHp = 4, startingHp = 4}
        },
        supplyTwo = {}
    })

    local ctx = {
        cfg = {},
        threatModel = require("ai_tournament.threat_model")
    }

    local deployEntries = supplyPlanner.getDeployActionEntries(ai, state, 1, ctx)
    local cloudEntry = nil
    for _, entry in ipairs(deployEntries or {}) do
        local action = entry.action or {}
        if action.unitName == "Cloudstriker" and action.target and action.target.row == 4 and action.target.col == 5 then
            cloudEntry = entry
            break
        end
    end
    assertTrue(cloudEntry ~= nil, "expected Cloudstriker lane deploy at 4,5")

    local classified = candidateBuckets.classifyAction(ai, state, cloudEntry.action, 1, ctx, {
        entry = cloudEntry
    })
    assertEquals(classified.bucket, "supply_offense", "Cloudstriker pressure lane should classify as supply_offense")
end)

runTest("full_hp_repair_remains_legal_but_is_bottom_bucketed", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local candidateBuckets = require("ai_tournament.candidate_buckets")
    local ai = mkAI(1)
    local state = fixtureLib.buildBaseState({
        actingPlayer = 1,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            {name = "Healer", player = 1, row = 4, col = 4, currentHp = 4, startingHp = 4},
            {name = "Wingstalker", player = 1, row = 4, col = 5, currentHp = 3, startingHp = 3},
            {name = "Crusher", player = 1, row = 5, col = 4, currentHp = 2, startingHp = 4}
        }
    })

    local legalWithoutException = ai:collectLegalActions(state, {
        aiPlayer = 1,
        includeMove = false,
        includeAttack = false,
        includeRepair = true,
        includeDeploy = false,
        allowFullHpHealerRepairException = false
    }) or {}
    local fullHpWithoutException = false
    for _, entry in ipairs(legalWithoutException) do
        if fixtureLib.actionSignature(entry.action) == "repair:4,4->4,5" then
            fullHpWithoutException = true
            break
        end
    end
    assertTrue(
        not fullHpWithoutException,
        "full-HP repair should not be emitted when the exception is disabled"
    )

    local legalWithException = ai:collectLegalActions(state, {
        aiPlayer = 1,
        includeMove = false,
        includeAttack = false,
        includeRepair = true,
        includeDeploy = false,
        allowFullHpHealerRepairException = true
    }) or {}

    local fullHpEntry = nil
    local damagedEntry = nil
    for _, entry in ipairs(legalWithException) do
        local signature = fixtureLib.actionSignature(entry.action)
        if signature == "repair:4,4->4,5" then
            fullHpEntry = entry
        elseif signature == "repair:4,4->5,4" then
            damagedEntry = entry
        end
    end
    assertTrue(fullHpEntry ~= nil, "full-HP repair should remain legal as a marked exception")
    assertTrue(fullHpEntry.mandatoryException == "healer_full_hp_repair", "full-HP repair should be tagged as an exception")
    assertTrue(damagedEntry ~= nil, "real damaged repair should still be present")

    local classified = candidateBuckets.classifyAction(ai, state, fullHpEntry.action, 1, {cfg = {}}, {
        entry = fullHpEntry
    })
    assertTrue(classified.tags.fullHpRepair == true, "full-HP repair should be explicitly tagged")
    assertTrue((classified.cheapScore or 0) <= -20000, "full-HP repair should be strongly disincentivized")
end)

runTest("bucket_quotas_preserve_rare_supply_entries", function()
    local candidateBuckets = require("ai_tournament.candidate_buckets")
    local entries = {}

    for i = 1, 60 do
        entries[#entries + 1] = {
            signature = "high#" .. tostring(i),
            bucket = "high_value_attack",
            cheapScore = 10000 - i
        }
    end
    entries[#entries + 1] = {
        signature = "rare_supply#1",
        bucket = "supply_defense",
        cheapScore = 5
    }

    local selected = candidateBuckets.selectByBuckets(entries, candidateBuckets.BUCKET_LIMITS, 40)
    local highCount = 0
    for _, entry in ipairs(selected) do
        if entry.bucket == "high_value_attack" then
            highCount = highCount + 1
        end
    end

    assertTrue(highCount <= candidateBuckets.BUCKET_LIMITS.high_value_attack, "high value actions should be capped by bucket quota")
    assertTrue(containsSignature(selected, "rare_supply#1"), "rare supply defense entry should survive bucket selection")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Candidate Buckets Smoke"
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
