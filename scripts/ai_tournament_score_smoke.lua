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

runTest("score_constructor_uses_normal_tier_and_defaults", function()
    local score = require("ai_tournament.score")
    local s = score.new("sig:a")

    assertEquals(s.tier, score.TIER.NORMAL, "new score should default to NORMAL tier")
    assertEquals(s.signature, "sig:a", "signature should be preserved")
    assertEquals(s.terminal, 0, "terminal should default 0")
    assertEquals(s.survival, 0, "survival should default 0")
    assertEquals(s.total, 0, "total should default 0")
end)

runTest("score_finalize_calculates_debug_total", function()
    local score = require("ai_tournament.score")
    local s = score.new("sig:total")
    s.terminal = 10
    s.survival = 20
    s.force = 30
    s.commandant = 40
    s.material = 50
    s.supply = 60
    s.position = 70
    s.risk = -5
    s.efficiency = 15

    score.finalize(s)
    assertEquals(s.total, 290, "finalize should compute debug total from tuple fields")
end)

runTest("terminal_tier_dominates_material", function()
    local score = require("ai_tournament.score")

    local terminalWin = score.new("A")
    terminalWin.tier = score.TIER.WIN_NOW
    terminalWin.terminal = 1000000
    terminalWin.material = -500

    local bigMaterial = score.new("B")
    bigMaterial.tier = score.TIER.MAJOR_ADVANTAGE
    bigMaterial.terminal = 0
    bigMaterial.material = 10000

    assertTrue(score.isBetter(terminalWin, bigMaterial), "terminal tier should dominate material")
    assertTrue(not score.isBetter(bigMaterial, terminalWin), "material should not beat WIN_NOW tier")
end)

runTest("survival_tuple_key_dominates_material_when_tier_equal", function()
    local score = require("ai_tournament.score")

    local defensive = score.new("A")
    defensive.tier = score.TIER.NORMAL
    defensive.survival = 500
    defensive.material = 50

    local greedy = score.new("B")
    greedy.tier = score.TIER.NORMAL
    greedy.survival = -200
    greedy.material = 900

    assertTrue(score.isBetter(defensive, greedy), "survival key should dominate material in lexicographic order")
end)

runTest("deterministic_signature_breaks_numeric_tie", function()
    local score = require("ai_tournament.score")

    local left = score.new("line:001")
    local right = score.new("line:999")

    assertTrue(score.isBetter(left, right), "lexicographically smaller signature should win numeric tie")
    assertTrue(not score.isBetter(right, left), "tie-break must be deterministic and asymmetric")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Score Tuple Smoke"
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
