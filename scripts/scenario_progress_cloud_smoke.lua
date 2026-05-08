package.path = "./?.lua;" .. package.path

local SAVE_DIR = "/tmp/meow_over_moo_scenario_progress_cloud_smoke"
local PROGRESS_PATH = SAVE_DIR .. "/ScenarioProgress.dat"

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

os.execute("rm -rf " .. shellQuote(SAVE_DIR))
os.execute("mkdir -p " .. shellQuote(SAVE_DIR))

_G.love = {
    filesystem = {
        getSaveDirectory = function()
            return SAVE_DIR
        end,
        read = function(fileName)
            local file = io.open(SAVE_DIR .. "/" .. tostring(fileName), "rb")
            if not file then
                return nil
            end
            local content = file:read("*a")
            file:close()
            return content
        end,
        write = function(fileName, content)
            local file = io.open(SAVE_DIR .. "/" .. tostring(fileName), "wb")
            if not file then
                return false
            end
            file:write(content)
            file:close()
            return true
        end
    }
}

package.loaded.scenario_progress = nil
local progress = require("scenario_progress")

local function assertTrue(value, message)
    if value ~= true then
        error(message or "assertion failed", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s (expected=%s actual=%s)", message or "assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

local initial = progress.load()
assertTrue(type(initial.scenarios) == "table", "missing file should load an empty scenario table")
assertEquals(next(initial.scenarios), nil, "missing progress file should not invent scenario entries")
assertEquals(progress.getEntry(initial, "P002").attempts, 0, "new scenario attempts should default to 0")
assertEquals(progress.getEntry(initial, "P002").solved, false, "new scenario solved should default to false")

progress.applyResult({ id = "P002", solved = false, attempts = 1 })
local saved = progress.load()
assertEquals(saved.scenarios.P002.attempts, 1, "first local attempt should save")
assertEquals(saved.scenarios.P002.solved, false, "failed attempt should remain unsolved")

local attemptEntry, attemptSaved = progress.recordAttempt("P002")
assertTrue(attemptSaved == true, "recordAttempt should report a successful save")
assertEquals(attemptEntry.attempts, 2, "recordAttempt should immediately increment attempts")
local attemptSavedData = progress.load()
assertEquals(attemptSavedData.scenarios.P002.attempts, 2, "recordAttempt should persist attempts immediately")

local diagnostics = progress.getDiagnostics()
assertEquals(diagnostics.fileName, "ScenarioProgress.dat", "Steam Cloud sync file name should stay stable")
assertEquals(diagnostics.storagePath, PROGRESS_PATH, "progress should resolve under LOVE save directory")
assertEquals(diagnostics.exists, true, "progress file should exist after save")
assertEquals(diagnostics.scenarioCount, 1, "diagnostics should count saved scenarios")

local cloudFile = io.open(PROGRESS_PATH, "wb")
assertTrue(cloudFile ~= nil, "failed to simulate Steam Cloud file download")
cloudFile:write('return {version=1,scenarios={P002={attempts=4,solved=true},P003={attempts=2,solved=false}}}\n')
cloudFile:close()

local synced = progress.load()
assertEquals(synced.scenarios.P002.attempts, 4, "load should pick up externally synced attempts")
assertEquals(synced.scenarios.P002.solved, true, "load should pick up externally synced solved state")
assertEquals(synced.scenarios.P003.attempts, 2, "load should pick up additional externally synced scenario")

os.remove(PROGRESS_PATH)
local reset = progress.load()
assertEquals(next(reset.scenarios), nil, "missing file after deletion should return empty defaults, not stale cache")

os.execute("rm -rf " .. shellQuote(SAVE_DIR))
print("scenario_progress_cloud_smoke: OK")
