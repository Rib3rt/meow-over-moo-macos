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

local function runCommand(command)
    local handle = io.popen(command .. " 2>&1")
    if not handle then
        return false, "", 1
    end
    local output = handle:read("*a") or ""
    local closeA, closeB, closeC = handle:close()
    if type(closeA) == "number" then
        return closeA == 0, output, closeA
    end
    if closeA == true then
        return true, output, 0
    end
    if closeB == "exit" and type(closeC) == "number" then
        return closeC == 0, output, closeC
    end
    return false, output, 1
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

runTest("probe_seed_6161_records_v2_decision_without_technical_fallback", function()
    local reportPath = "/tmp/tournament_probe_smoke.md"
    os.remove(reportPath)

    local command = table.concat({
        "lua scripts/ai_strength_eval.lua",
        "--matches 1",
        "--max-rounds 1",
        "--seed 6161",
        "--p1-ref base",
        "--p2-ref burt",
        "--p1-tournament true",
        "--p2-tournament false",
        "--report " .. reportPath
    }, " ")

    local ok, output, code = runCommand(command)
    assertTrue(ok, "probe command failed with exit " .. tostring(code) .. "\n" .. tostring(output))

    local report = readFile(reportPath) or output or ""
    local decisions = tonumber((report:match("%- decisions with tournament meta:%s*`(%d+)`")))
    assertTrue(decisions ~= nil, "unable to parse `decisions with tournament meta` from probe report")
    assertTrue(decisions >= 1, "expected at least one V2 tournament decision, got " .. tostring(decisions))

    local technicalFallback = tonumber((report:match("%- technical fallback contracts:%s*`(%d+)`")))
    assertTrue(technicalFallback ~= nil, "unable to parse `technical fallback contracts` from probe report")
    assertTrue(technicalFallback == 0, "probe should not need technical fallback, got " .. tostring(technicalFallback))

    assertTrue(
        report:find("core exits: `pipeline_v2_selected`=", 1, true) ~= nil,
        "probe should report a V2-selected core exit"
    )
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Probe Smoke"
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
