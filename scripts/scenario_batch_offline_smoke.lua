package.path = package.path .. ";./?.lua"

local batchOffline = require("scenario_tooling.batch_offline")

local results = {}

local function runTest(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = { name = name, ok = ok, err = err }
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

local function approvedIds(report)
    local ids = {}
    for _, entry in ipairs(report.approved or {}) do
        ids[#ids + 1] = entry.dossier and entry.dossier.id or entry.id
    end
    return table.concat(ids, "|")
end

runTest("batch_offline_is_scenario_only_and_versioned", function()
    assertTrue(batchOffline.isScenarioOnly() == true, "batch runner should be scenario-only")
    assertTrue(type(batchOffline.VERSION) == "string" and batchOffline.VERSION ~= "", "version required")
    assertTrue(type(batchOffline.BATCH_ID) == "string" and batchOffline.BATCH_ID ~= "", "batch id required")
    assertTrue(type(batchOffline.BATCH_HASH) == "string" and batchOffline.BATCH_HASH ~= "", "batch hash required")
end)

runTest("batch_run_produces_approved_candidates_and_clean_approved_folder", function()
    local report = batchOffline.run({ seed = 500, count = 3, turnLimit = 3 })
    assertEquals(report.status, "completed", "batch should complete")
    assertEquals(report.requestedCount, 3, "requested count")
    assertEquals(report.completedCount, 3, "completed count")
    assertEquals(report.approvedCount, 3, "all controlled generated candidates should approve")
    assertEquals(report.approvedFolderClean, true, "approved folder must be clean")
    for _, entry in ipairs(report.approved or {}) do
        assertEquals(entry.quality.status, "approved", "approved entry quality")
        assertEquals(entry.dossier.pipelineState, "certified", "approved entry certified")
    end
end)

runTest("batch_run_is_reproducible_for_same_seed", function()
    local first = batchOffline.run({ seed = 510, count = 3, turnLimit = 3 })
    local second = batchOffline.run({ seed = 510, count = 3, turnLimit = 3 })
    assertEquals(first.approvedCount, second.approvedCount, "approved count reproducible")
    assertEquals(approvedIds(first), approvedIds(second), "approved ids reproducible")
    assertEquals(first.checkpoint.nextIndex, second.checkpoint.nextIndex, "checkpoint reproducible")
end)

runTest("batch_resume_matches_single_full_run", function()
    local partial = batchOffline.run({ seed = 520, count = 2, turnLimit = 3 })
    local resumed = batchOffline.resume(partial.checkpoint, { count = 4 })
    local full = batchOffline.run({ seed = 520, count = 4, turnLimit = 3 })
    assertEquals(resumed.completedCount, 4, "resumed completed count")
    assertEquals(resumed.approvedCount, full.approvedCount, "resumed approved count")
    assertEquals(approvedIds(resumed), approvedIds(full), "resumed approved ids match full run")
end)

runTest("batch_reject_log_is_readable_for_failed_attempts", function()
    local report = batchOffline.run({ seed = 530, count = 2, turnLimit = 2 })
    assertTrue(report.approvedCount == 0, "invalid turn limit should not approve")
    assertTrue(#(report.rejectLog or {}) >= 1, "reject log entries required")
    local text = batchOffline.formatRejectLog(report)
    assertTrue(type(text) == "string" and text:find("precheck_failed", 1, true) ~= nil, "readable reject log should include reason")
end)

runTest("batch_offline_has_no_standard_ai_dependency", function()
    local file = io.open("scenario_tooling/batch_offline.lua", "r")
    assertTrue(file ~= nil, "batch_offline.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('require("ai', 1, true) == nil, "batch runner must not require standard AI")
    assertTrue(content:find("require('ai", 1, true) == nil, "batch runner must not require standard AI")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "batch runner must not depend on AI tournament modules")
    assertTrue(content:find("ai_config", 1, true) == nil, "batch runner must not depend on AI config")
    assertTrue(content:find("gameRuler", 1, true) == nil, "batch runner must not depend on runtime game ruler")
    assertTrue(content:find("factionSelect", 1, true) == nil, "batch runner must not depend on runtime menus")
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

print(string.format("scenario_batch_offline_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
