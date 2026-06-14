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

local function ctx(reference)
    return {
        aiPlayer = 1,
        enemyPlayer = 2,
        aiReference = reference,
        cfg = {},
        stats = {}
    }
end

local function ai(reference)
    return {
        aiReference = reference
    }
end

local function contestedCell()
    return {
        key = "4,4",
        row = 4,
        col = 4,
        value = 100,
        status = "contested_pressure",
        free = true,
        reachable = true,
        deployable = false,
        attackableEnemy = true,
        directlyAttackableByEnemy = true,
        attackContested = true,
        influenceContested = true,
        potentialInfluenceContested = true,
        ownAttackCount = 1,
        ownMoveAttackCount = 0,
        enemyAttackCount = 1,
        enemyMoveAttackCount = 0,
        pressureQuestionValue = 100,
        tradeNet = 0,
        coveredIfOccupied = false,
        progress = 4,
        enemyHubDistance = 5
    }
end

local function safeCell()
    return {
        key = "3,4",
        row = 3,
        col = 4,
        value = 90,
        status = "advance_cell",
        free = true,
        reachable = true,
        deployable = false,
        attackableEnemy = false,
        directlyAttackableByEnemy = false,
        attackContested = false,
        influenceContested = false,
        potentialInfluenceContested = false,
        ownAttackCount = 0,
        ownMoveAttackCount = 0,
        enemyAttackCount = 0,
        enemyMoveAttackCount = 0,
        pressureQuestionValue = 40,
        tradeNet = 1,
        coveredIfOccupied = true,
        progress = 3,
        enemyHubDistance = 6
    }
end

runTest("mid_personality_reads_same_map_differently", function()
    local personality = require("ai_tournament.mid_personality")
    local midMap = {
        cells = {
            contestedCell(),
            safeCell()
        }
    }

    local marge = personality.interpretMap(ai("marge"), nil, ctx("marge"), midMap, {limit = 2})
    local burt = personality.interpretMap(ai("burt"), nil, ctx("burt"), midMap, {limit = 2})

    assertTrue(marge.top[1].key == "3,4", "Marge should prefer covered positional presence")
    assertTrue(burt.top[1].key == "4,4", "Burt should prefer contested pressure")
    assertTrue(
        burt.byKey["4,4"].value > marge.byKey["4,4"].value,
        "aggressive interpretation should value the same contested cell more"
    )
end)

runTest("mid_personality_aggression_spectrum_orders_attack_pressure", function()
    local personality = require("ai_tournament.mid_personality")
    local cell = contestedCell()

    local marge = personality.scoreCell(ai("marge"), nil, ctx("marge"), cell)
    local lisa = personality.scoreCell(ai("lisa"), nil, ctx("lisa"), cell)
    local burt = personality.scoreCell(ai("burt"), nil, ctx("burt"), cell)
    local burns = personality.scoreCell(ai("burns"), nil, ctx("burns"), cell)

    assertTrue(lisa.personality == "lisa", "Lisa should expose the neutral profile identity")
    assertTrue(marge.value < lisa.value, "Marge should value contested pressure below neutral Lisa")
    assertTrue(lisa.value < burt.value, "Burt should value contested pressure above neutral Lisa")
    assertTrue(burt.value < burns.value, "Burns should be the most aggressive contested interpreter")
    assertTrue(
        burns.thresholds.attackMinTradeNet < burt.thresholds.attackMinTradeNet,
        "Burns should accept thinner attack trades than Burt"
    )
end)

runTest("mid_personality_exposes_thresholds_and_risk_band", function()
    local personality = require("ai_tournament.mid_personality")
    local scored = personality.scoreCell(ai("marge"), nil, ctx("marge"), contestedCell())

    assertTrue(scored.personality == "marge", "score should expose personality")
    assertTrue(scored.riskBand == "contested_bad_trade", "Marge should read weak contested trades as bad")
    assertTrue(scored.thresholds.minTradeNet == 2, "Marge should require stronger trades")
end)

runTest("mid_personality_supports_barnes_alias", function()
    local personality = require("ai_tournament.mid_personality")
    local profile = personality.resolve(ai("barnes"), nil, ctx("barnes"))

    assertTrue(profile.reference == "barnes", "reference should preserve selected identity")
    assertTrue(profile.name == "burt", "Barnes should currently reuse the aggressive profile")
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
    print(string.format("ai_tournament_mid_personality_smoke failed: %d/%d", failed, #results))
    os.exit(1)
end

print(string.format("ai_tournament_mid_personality_smoke passed: %d/%d", #results, #results))
