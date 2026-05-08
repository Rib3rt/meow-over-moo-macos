package.path = package.path .. ";./?.lua"

local unitsInfo = require("unitsInfo")

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

local function loadScenario(path)
    local chunk, err = loadfile(path)
    assertTrue(type(chunk) == "function", "failed to load " .. tostring(path) .. ": " .. tostring(err))
    local ok, payload = pcall(chunk)
    assertTrue(ok, "scenario chunk failed " .. tostring(path) .. ": " .. tostring(payload))
    assertTrue(type(payload) == "table", "scenario payload must be a table: " .. tostring(path))
    return payload
end

local function readFile(path)
    local file = io.open(path, "r")
    assertTrue(file ~= nil, "failed to read " .. tostring(path))
    local content = file:read("*a")
    file:close()
    return content
end

local function countBoardUnitsByPlayer(snapshot)
    local counts = { [0] = 0, [1] = 0, [2] = 0 }
    local redCommandants = 0
    for _, unit in ipairs(snapshot.boardUnits or {}) do
        local player = tonumber(unit.player) or 0
        counts[player] = (counts[player] or 0) + 1
        if player == 2 and unit.name == "Commandant" then
            redCommandants = redCommandants + 1
        end
    end
    return counts, redCommandants
end

local function boardSignature(snapshot)
    local parts = {}
    for _, unit in ipairs(snapshot.boardUnits or {}) do
        parts[#parts + 1] = table.concat({
            tostring(unit.scenarioUnitId or ""),
            tostring(unit.player or ""),
            tostring(unit.name or ""),
            tostring(unit.row or ""),
            tostring(unit.col or ""),
            tostring(unit.currentHp or ""),
            tostring(unit.startingHp or "")
        }, ":")
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

runTest("public_p001_p002_are_promoted_release_levels", function()
    local expected = {
        P001 = {
            originalExportId = "Scenario#20260505115547-384",
            blue = 2,
            red = 3,
            neutral = 0
        },
        P002 = {
            originalExportId = "Scenario#20260505171632-565",
            blue = 2,
            red = 4,
            neutral = 2
        }
    }
    local signatures = {}
    for scenarioId, expectation in pairs(expected) do
        local path = "scenarios/" .. scenarioId .. ".lua"
        local scenario = loadScenario(path)
        assertTrue(scenario.id == scenarioId, scenarioId .. " id mismatch")
        assertTrue(scenario.name == "Scenario " .. scenarioId, scenarioId .. " name mismatch")
        assertTrue(scenario.status == "PROMOTED", scenarioId .. " should be promoted")
        assertTrue(type(scenario.promotion) == "table", scenarioId .. " should include promotion metadata")
        assertTrue(scenario.promotion.state == "promoted", scenarioId .. " promotion state should be promoted")
        assertTrue(scenario.promotion.approved == true, scenarioId .. " should carry approval")
        assertTrue(scenario.promotion.originalExportId == expectation.originalExportId, scenarioId .. " should preserve source export id")
        assertTrue(scenario.turnLimitRounds == 3, scenarioId .. " should preserve turn limit")
        assertTrue(type(scenario.scenarioRedPolicy) == "table", scenarioId .. " must include Scenario Red Policy metadata")
        assertTrue(scenario.scenarioRedPolicy.runtime == "scenarioRedRuntime", scenarioId .. " must use shipped scenario red runtime")
        assertTrue(scenario.scenarioRedPolicy.policy == "scenarioRedPolicy", scenarioId .. " must use shipped scenario red policy")

        local snapshot = scenario.startSnapshot
        assertTrue(type(snapshot) == "table", scenarioId .. " missing startSnapshot")
        assertTrue(snapshot.currentPhase == "turn", scenarioId .. " should open directly into turn phase")
        assertTrue(snapshot.currentTurnPhase == "actions", scenarioId .. " should open on Blue actions")
        assertTrue(snapshot.currentPlayer == 1, scenarioId .. " should start with Blue to move")
        assertTrue(snapshot.maxActionsPerTurn == 2, scenarioId .. " must keep two-action budget")

        local counts, redCommandants = countBoardUnitsByPlayer(snapshot)
        assertTrue((counts[1] or 0) == expectation.blue, scenarioId .. " should preserve expected Blue count")
        assertTrue((counts[2] or 0) == expectation.red, scenarioId .. " should preserve expected Red count")
        assertTrue((counts[0] or 0) == expectation.neutral, scenarioId .. " should preserve expected neutral count")
        assertTrue(redCommandants == 1, scenarioId .. " needs exactly one Red Commandant")
        assertTrue(type(snapshot.commandHubPositions) == "table", scenarioId .. " missing commandHubPositions")
        assertTrue(type(snapshot.commandHubPositions[2]) == "table", scenarioId .. " missing Red Commandant hub position")
        signatures[scenarioId] = boardSignature(snapshot)
    end
    assertTrue(signatures.P001 ~= signatures.P002, "P001 and P002 must be different promoted boards")
end)

runTest("scenario_directory_contains_public_p001_through_p010", function()
    local pipe = io.popen("find scenarios -maxdepth 1 -type f -name '*.lua' | sort")
    assertTrue(pipe ~= nil, "failed to enumerate scenarios")
    local paths = {}
    for line in pipe:lines() do
        paths[#paths + 1] = line
    end
    pipe:close()
    assertTrue(#paths == 10, "P001 through P010 should be public scenario files")
    assertTrue(paths[1] == "scenarios/P001.lua", "P001 should be first public scenario")
    assertTrue(paths[2] == "scenarios/P002.lua", "P002 should be second public scenario")
    assertTrue(paths[3] == "scenarios/P003.lua", "P003 should be third public scenario")
    assertTrue(paths[4] == "scenarios/P004.lua", "P004 should be fourth public scenario")
    assertTrue(paths[5] == "scenarios/P005.lua", "P005 should be fifth public scenario")
    assertTrue(paths[6] == "scenarios/P006.lua", "P006 should be sixth public scenario")
    assertTrue(paths[7] == "scenarios/P007.lua", "P007 should be seventh public scenario")
    assertTrue(paths[8] == "scenarios/P008.lua", "P008 should be eighth public scenario")
    assertTrue(paths[9] == "scenarios/P009.lua", "P009 should be ninth public scenario")
    assertTrue(paths[10] == "scenarios/P010.lua", "P010 should be tenth public scenario")
end)

runTest("public_scenarios_do_not_depend_on_over_base_hp", function()
    for index = 1, 10 do
        local path = string.format("scenarios/P%03d.lua", index)
        local scenario = loadScenario(path)
        for _, unit in ipairs((scenario.startSnapshot or {}).boardUnits or {}) do
            local info = unitsInfo:getUnitInfo(unit.name)
            local baseHp = info and tonumber(info.startingHp or info.hp) or nil
            assertTrue(baseHp ~= nil, path .. " unknown unit type " .. tostring(unit.name))
            local currentHp = tonumber(unit.currentHp)
            assertTrue(currentHp ~= nil, path .. " unit missing currentHp")
            assertTrue(
                currentHp <= baseHp,
                string.format("%s %s at %s,%s has impossible HP %s/%s", path, tostring(unit.name), tostring(unit.row), tostring(unit.col), tostring(currentHp), tostring(baseHp))
            )
        end
    end
end)

runTest("manual_p003_is_distinct_four_turn_capture_discipline", function()
    local scenario = loadScenario("scenarios/P003.lua")
    assertTrue(scenario.id == "P003", "manual test scenario id mismatch")
    assertTrue(scenario.name == "Scenario P003", "P003 public name should stay numeric")
    assertTrue(scenario.turnLimitRounds == 4, "P003 should test the four-turn capture-discipline puzzle path")
    assertTrue(scenario.promotion.source == "manual_playtest_capture_discipline_4", "P003 should be marked as the capture-discipline playtest")
    assertTrue(type(scenario.scenarioRedPolicy) == "table", "P003 must use Scenario Red Policy")
    assertTrue(scenario.scenarioRedPolicy.runtime == "scenarioRedRuntime", "P003 must use the shipped scenario runtime policy")
    assertTrue(#(scenario.scenarioRedPolicy.criticalBlueUnitIds or {}) == 3, "P003 should declare the finisher, opener, and screen roles")

    local snapshot = scenario.startSnapshot
    local counts, redCommandants = countBoardUnitsByPlayer(snapshot)
    assertTrue((counts[1] or 0) == 3, "P003 should use three Blue role units")
    assertTrue((counts[2] or 0) == 3, "P003 should include Commandant plus two active Red pressure units")
    assertTrue((counts[0] or 0) == 2, "P003 should include two neutral route locks")
    assertTrue(redCommandants == 1, "P003 needs exactly one Red Commandant")
end)

runTest("retired_save_exports_are_not_left_for_discovery", function()
    local saveDir = "/Users/mdc/Library/Application Support/LOVE/MeowOverMoo"
    local command = "find " .. string.format("%q", saveDir)
        .. " -maxdepth 3 -type f \\( -path '*/scenarios/*.lua' -o -path '*/scenario_dossiers/*.lua' -o -path '*/scenario_solutions/*.lua' \\) | sort"
    local pipe = io.popen(command)
    assertTrue(pipe ~= nil, "failed to enumerate save exports")
    local paths = {}
    for line in pipe:lines() do
        paths[#paths + 1] = line
    end
    pipe:close()
    assertTrue(#paths == 0, "retired exported scenarios should not be discoverable from save directory")
end)

runTest("public_p001_is_playable_and_manually_promoted", function()
    local path = "scenarios/P001.lua"
    local scenario = loadScenario(path)
    assertTrue(scenario.id == "P001", "exported scenario id mismatch")
    assertTrue(scenario.status == "PROMOTED", "editor export should be manually promoted")
    assertTrue(type(scenario.promotion) == "table", "editor export should include promotion metadata")
    assertTrue(scenario.promotion.state == "promoted", "editor export promotion state should be promoted")
    assertTrue(scenario.promotion.approved == true, "editor export should carry manual approval")
    assertTrue(scenario.promotion.source == "verified_export_promoted_to_public_slot", "public slot should record verified export promotion source")
    assertTrue(scenario.turnLimitRounds == 3, "exported scenario should preserve editor turn limit")
    assertTrue(type(scenario.scenarioRedPolicy) == "table", "exported scenario must include Scenario Red Policy metadata")
    assertTrue(scenario.scenarioRedPolicy.runtime == "scenarioRedRuntime", "exported scenario must use shipped scenario red runtime")
    assertTrue(scenario.scenarioRedPolicy.policy == "scenarioRedPolicy", "exported scenario must use shipped scenario red policy")

    local snapshot = scenario.startSnapshot
    assertTrue(type(snapshot) == "table", "exported scenario missing startSnapshot")
    assertTrue(snapshot.currentPhase == "turn", "exported scenario should open directly into turn phase")
    assertTrue(snapshot.currentTurnPhase == "actions", "exported scenario should open on Blue actions")
    assertTrue(snapshot.currentPlayer == 1, "exported scenario should start with Blue to move")
    assertTrue(snapshot.maxActionsPerTurn == 2, "exported scenario must keep two-action budget")

    local counts, redCommandants = countBoardUnitsByPlayer(snapshot)
    assertTrue((counts[1] or 0) > 0, "exported scenario needs at least one Blue unit")
    assertTrue((counts[2] or 0) > 0, "exported scenario needs at least one Red unit")
    assertTrue(redCommandants == 1, "exported scenario needs exactly one Red Commandant")
    assertTrue(type(snapshot.commandHubPositions) == "table", "exported scenario missing commandHubPositions")
    assertTrue(type(snapshot.commandHubPositions[2]) == "table", "exported scenario missing Red Commandant hub position")
end)

runTest("p001_is_explicitly_promoted", function()
    local scenario = loadScenario("scenarios/P001.lua")
    assertTrue(scenario.status == "PROMOTED", "public scenario must be explicitly promoted")
    assertTrue(type(scenario.promotion) == "table", "public scenario should include promotion metadata")
    assertTrue(scenario.promotion.approved == true, "public scenario should be marked approved")
end)

runTest("scenario_editor_export_writes_sidecar_dossier_contract", function()
    local content = readFile("scenarioEditor.lua")
    assertTrue(content:find('SCENARIO_EXPORT_STATUS = "PROMOTED"', 1, true) ~= nil, "editor exports must be promoted by the editor")
    assertTrue(content:find('SCENARIO_DOSSIER_DIR = "scenario_dossiers"', 1, true) ~= nil, "editor exports must write proof sidecars")
    assertTrue(content:find("SCENARIO_SOLUTION_DIR", 1, true) ~= nil or content:find("scenario_solutions", 1, true) ~= nil, "editor exports must write solution sidecars")
    assertTrue(content:find("buildScenarioExportDossierContent", 1, true) ~= nil, "editor export must serialize a dossier sidecar")
    assertTrue(content:find("buildScenarioExportSolutionContent", 1, true) ~= nil or content:find("solution sidecar", 1, true) ~= nil, "editor export must serialize a solution sidecar")
    assertTrue(content:find("proofAppliesToCurrentSnapshot", 1, true) ~= nil, "sidecar must state whether proof matches current snapshot")
    assertTrue(content:find("sourceDossierStale", 1, true) ~= nil, "sidecar must expose stale proof state")
    assertTrue(content:find("sourceSolutionStale", 1, true) ~= nil or content:find("staleSolution", 1, true) ~= nil, "sidecar must expose stale solution state")
    assertTrue(content:find("editorBoardDirtySinceDossier", 1, true) ~= nil, "manual edits must be tracked after generation")
    assertTrue(content:find("manualPromotion = true", 1, true) ~= nil, "sidecar must record editor export as manual promotion")
    assertTrue(content:find("solutionPath", 1, true) ~= nil, "scenario payload and sidecars must store solutionPath metadata")
    assertTrue(content:find("writeScenarioExportFile(dossierPath", 1, true) ~= nil, "dossier sidecar must be written during export")
    assertTrue(content:find("writeScenarioExportFile(solutionPath", 1, true) ~= nil, "solution sidecar must be written during export")
end)

runTest("scenario_editor_solution_sidecar_preserves_full_action_fields", function()
    local content = readFile("scenarioEditor.lua")
    assertTrue(content:find("canonicalExportActionList(sourceSolutionRaw and sourceSolutionRaw.actions or {})", 1, true) ~= nil, "solution sidecar should canonicalize full source action objects")
    assertTrue(content:find("canonicalExportActionList(sourceDossierRaw.solverProof.winningLine or {})", 1, true) ~= nil, "solution sidecar should preserve full fallback winning line actions")
    assertTrue(content:find("actions = actions,", 1, true) ~= nil, "solution sidecar should write raw action objects")
    assertTrue(content:find("solution = { actions = cloneValue(actions) }", 1, true) ~= nil, "solution sidecar should keep nested solution actions with full fields")
    assertTrue(content:find("serializeLuaValue(exportSolution, 0)", 1, true) ~= nil, "solution sidecar should serialize the full solution payload")
end)

runTest("scenario_select_registers_only_promoted_payloads", function()
    local content = readFile("scenarioSelect.lua")
    assertTrue(content:find("PROMOTED_SCENARIO_STATUSES", 1, true) ~= nil, "scenario select must define promotion statuses")
    assertTrue(content:find("isPromotedScenarioPayload", 1, true) ~= nil, "scenario select must filter by promotion")
    assertTrue(content:find("if not isPromotedScenarioPayload(rowData) then", 1, true) ~= nil, "non-promoted scenario payloads must not be registered")
end)

runTest("all_versioned_scenario_files_load", function()
    local pipe = io.popen("find scenarios -maxdepth 1 -type f -name '*.lua' | sort")
    assertTrue(pipe ~= nil, "failed to enumerate scenarios")
    local paths = {}
    for line in pipe:lines() do
        paths[#paths + 1] = line
    end
    pipe:close()
    assertTrue(#paths > 0, "no scenario files found")

    for _, path in ipairs(paths) do
        local scenario = loadScenario(path)
        assertTrue(type(scenario.id) == "string" and scenario.id ~= "", "scenario missing id: " .. path)
        assertTrue(type(scenario.startSnapshot or scenario.snapshot) == "table", "scenario missing snapshot: " .. path)
    end
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
        print("[PASS] " .. result.name)
    else
        print("[FAIL] " .. result.name .. ": " .. tostring(result.err))
    end
end

print(string.format("scenario_export_import_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
