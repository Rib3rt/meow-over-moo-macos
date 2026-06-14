package.path = package.path .. ";./?.lua"

local finisherLibrary = require("scenario_tooling.finisher_library")
local stateEngine = require("scenario_tooling.state_engine")
local solver = require("scenario_tooling.solver")

local results = {}

local function runTest(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = {name = name, ok = ok, err = err}
end

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message or "assertEquals failed", tostring(expected), tostring(actual)), 2)
    end
end

local function cellKey(cell)
    return tostring(cell.row) .. ":" .. tostring(cell.col)
end

local function asSet(cells)
    local out = {}
    for _, cell in ipairs(cells or {}) do
        out[cellKey(cell)] = true
    end
    return out
end

runTest("finisher_library_is_scenario_only_and_versioned", function()
    assertTrue(finisherLibrary.isScenarioOnly() == true, "finisher library should be scenario-only")
    assertTrue(type(finisherLibrary.VERSION) == "string" and finisherLibrary.VERSION ~= "", "version required")
    assertTrue(type(finisherLibrary.LIBRARY_HASH) == "string" and finisherLibrary.LIBRARY_HASH ~= "", "hash required")
end)

runTest("finisher_library_exposes_three_controlled_finishers", function()
    local finishers = finisherLibrary.listFinishers()
    assertEquals(#finishers, 3, "controlled V1 finisher count")
    assertTrue(finisherLibrary.getFinisher("cloudstriker_ranged") ~= nil, "Cloudstriker finisher missing")
    assertTrue(finisherLibrary.getFinisher("crusher_melee") ~= nil, "Crusher finisher missing")
    assertTrue(finisherLibrary.getFinisher("artillery_ranged") ~= nil, "Artillery finisher missing")
end)

runTest("each_finisher_declares_supported_and_blacklisted_a1_h2_cells", function()
    for _, finisher in ipairs(finisherLibrary.listFinishers()) do
        local supported = finisherLibrary.supportedCommandantCells(finisher.id)
        local unsupported = finisherLibrary.unsupportedCommandantCells(finisher.id)
        local total = #supported + #unsupported
        assertEquals(total, 16, finisher.id .. " should account for every A1-H2 cell")

        local seen = {}
        for _, cell in ipairs(supported) do
            local key = cellKey(cell)
            assertTrue(not seen[key], finisher.id .. " duplicate cell " .. key)
            seen[key] = true
            assertTrue(cell.row >= 1 and cell.row <= 2 and cell.col >= 1 and cell.col <= 8, finisher.id .. " supported cell outside A1-H2")
        end
        for _, cell in ipairs(unsupported) do
            local key = cellKey(cell)
            assertTrue(not seen[key], finisher.id .. " duplicate support/blacklist cell " .. key)
            seen[key] = true
            assertTrue(cell.row >= 1 and cell.row <= 2 and cell.col >= 1 and cell.col <= 8, finisher.id .. " unsupported cell outside A1-H2")
        end
    end
end)

runTest("supported_finisher_mate_fixtures_are_legal_and_solved", function()
    for _, finisher in ipairs(finisherLibrary.listFinishers()) do
        local supported = finisherLibrary.supportedCommandantCells(finisher.id)
        assertTrue(#supported > 0, finisher.id .. " needs at least one supported cell")
        local fixture, reason = finisherLibrary.buildMateFixture(finisher.id, supported[1])
        assertTrue(type(fixture) == "table", finisher.id .. " mate fixture failed: " .. tostring(reason))
        local actions = stateEngine.getLegalActions(fixture)
        local foundAttack = false
        for _, action in ipairs(actions) do
            if action.type == "attack" and action.actorId == finisher.id .. "_unit" and action.targetId == "red_commandant" then
                foundAttack = true
            end
        end
        assertTrue(foundAttack, finisher.id .. " final attack should be legal")

        local proof = solver.solve(fixture, {proofDomain = "all_legal", maxPlies = 2})
        assertEquals(proof.status, "forced_win", finisher.id .. " mate fixture should solve")
    end
end)

runTest("unsupported_finisher_cells_do_not_build_fixtures", function()
    for _, finisher in ipairs(finisherLibrary.listFinishers()) do
        local unsupported = finisherLibrary.unsupportedCommandantCells(finisher.id)
        if #unsupported > 0 then
            local fixture, reason = finisherLibrary.buildMateFixture(finisher.id, unsupported[1])
            assertEquals(fixture, nil, finisher.id .. " unsupported cell should not build")
            assertTrue(type(reason) == "string" and reason ~= "", finisher.id .. " unsupported reason required")
        end
    end
end)

runTest("cloudstriker_and_artillery_have_distinct_blocker_contracts", function()
    local cloud = finisherLibrary.getFinisher("cloudstriker_ranged")
    local artillery = finisherLibrary.getFinisher("artillery_ranged")
    assertEquals(cloud.losRequired, true, "Cloudstriker should require LOS")
    assertEquals(cloud.canShootThroughBlockers, false, "Cloudstriker should not shoot through blockers")
    assertEquals(artillery.losRequired, false, "Artillery should not require LOS")
    assertEquals(artillery.canShootThroughBlockers, true, "Artillery should shoot through blockers")
end)

runTest("validate_library_reports_all_finishers_ok", function()
    local ok, reports = finisherLibrary.validateLibrary()
    assertTrue(ok, "library should validate")
    assertEquals(#reports, 3, "one report per finisher")
    for _, report in ipairs(reports) do
        assertEquals(report.ok, true, report.id .. " report should pass")
    end
end)

runTest("finisher_library_has_no_standard_ai_dependency", function()
    local file = io.open("scenario_tooling/finisher_library.lua", "r")
    assertTrue(file ~= nil, "finisher_library.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('require("ai', 1, true) == nil, "finisher library must not require standard AI")
    assertTrue(content:find("require('ai", 1, true) == nil, "finisher library must not require standard AI")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "finisher library must not depend on AI tournament modules")
    assertTrue(content:find("gameplay", 1, true) == nil, "finisher library must not depend on gameplay")
    assertTrue(content:find("gameRuler", 1, true) == nil, "finisher library must not depend on gameRuler")
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
        print("[PASS] " .. result.name)
    else
        print("[FAIL] " .. result.name .. " -> " .. tostring(result.err))
    end
end

print(string.format("scenario_finisher_library_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
