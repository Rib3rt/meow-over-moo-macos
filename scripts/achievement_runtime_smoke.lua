package.path = package.path .. ";./?.lua"

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

local function resetModules()
    package.loaded["achievement_runtime"] = nil
    package.loaded["achievement_defs"] = nil
    package.loaded["steam_runtime"] = nil
    package.preload["achievement_defs"] = nil
    package.preload["steam_runtime"] = nil
end

runTest("achievement_runtime_unlock_dedupes_repeated_unlocks", function()
    resetModules()
    package.preload["steam_runtime"] = function()
        local calls = {
            setAchievement = 0,
            storeUserStats = 0
        }

        return {
            _calls = calls,
            getAchievement = function(id)
                return false
            end,
            setAchievement = function(id)
                calls.setAchievement = calls.setAchievement + 1
                return true
            end,
            storeUserStats = function()
                calls.storeUserStats = calls.storeUserStats + 1
                return true
            end
        }
    end

    local runtime = require("achievement_runtime")
    local steamRuntime = require("steam_runtime")
    runtime.init()

    assertTrue(runtime.unlock("ACH_TEST") == true, "first unlock should succeed")
    assertTrue(runtime.unlock("ACH_TEST") == true, "second unlock should dedupe as success")
    assertTrue(steamRuntime._calls.setAchievement == 1, "setAchievement should be called once for deduped unlocks")
end)

runTest("achievement_runtime_flush_stores_only_when_dirty", function()
    resetModules()
    package.preload["steam_runtime"] = function()
        local calls = {
            setAchievement = 0,
            storeUserStats = 0
        }

        return {
            _calls = calls,
            getAchievement = function(id)
                return false
            end,
            setAchievement = function(id)
                calls.setAchievement = calls.setAchievement + 1
                return true
            end,
            storeUserStats = function()
                calls.storeUserStats = calls.storeUserStats + 1
                return true
            end
        }
    end

    local runtime = require("achievement_runtime")
    local steamRuntime = require("steam_runtime")
    runtime.init()

    assertTrue(runtime.flush() == true, "clean flush should succeed")
    assertTrue(steamRuntime._calls.storeUserStats == 0, "clean flush should not call storeUserStats")
    assertTrue(runtime.unlock("ACH_TEST") == true, "unlock should mark runtime dirty")
    assertTrue(runtime.flush() == true, "dirty flush should succeed")
    assertTrue(steamRuntime._calls.storeUserStats == 1, "dirty flush should store stats once")
end)

runTest("achievement_runtime_record_uses_registered_handlers_only", function()
    resetModules()
    package.preload["steam_runtime"] = function()
        return {
            getAchievement = function(id)
                return false
            end,
            setAchievement = function(id)
                return true
            end,
            storeUserStats = function()
                return true
            end
        }
    end
    package.preload["achievement_defs"] = function()
        return {
            VERSION = 1,
            ACHIEVEMENTS = {},
            STATS = {},
            EVENT_HANDLERS = {
                sample_event = function(runtime, payload)
                    return runtime.unlock(payload.id)
                end
            }
        }
    end

    local runtime = require("achievement_runtime")
    runtime.init()

    local handled = runtime.record("sample_event", {id = "ACH_EVENT"})
    assertTrue(handled == true, "registered event handler should unlock achievement")
    local ignored, reason = runtime.record("unknown_event", {})
    assertTrue(ignored == false, "unknown event should not be handled")
    assertTrue(reason == "no_handler", "unknown event should report no_handler")
end)

runTest("achievement_defs_gameplay_started_unlocks_first_orders_and_local_play", function()
    resetModules()
    local unlocked = {}
    package.preload["steam_runtime"] = function()
        return {
            getAchievement = function()
                return false
            end,
            setAchievement = function(id)
                unlocked[id] = true
                return true
            end,
            storeUserStats = function()
                return true
            end
        }
    end

    local runtime = require("achievement_runtime")
    runtime.init()
    assertTrue(runtime.record("gameplay_started", {mode = "localMultyplayer", resumed = false}) == true, "gameplay_started should be handled")
    assertTrue(unlocked.ACH_FIRST_ORDERS == true, "first orders should unlock")
    assertTrue(unlocked.ACH_PLAY_LOCAL == true, "local play should unlock")
end)

runTest("achievement_defs_match_completed_unlocks_ai_and_victory_achievements", function()
    resetModules()
    local unlocked = {}
    package.preload["steam_runtime"] = function()
        return {
            getAchievement = function()
                return false
            end,
            setAchievement = function(id)
                unlocked[id] = true
                return true
            end,
            storeUserStats = function()
                return true
            end
        }
    end

    local runtime = require("achievement_runtime")
    runtime.init()
    assertTrue(runtime.record("match_completed", {
        mode = "singlePlayer",
        localUserWon = true,
        opponentControllerType = "ai",
        opponentControllerNickname = "Burns (AI)",
        victoryReason = "commandant"
    }) == true, "match_completed should be handled")
    assertTrue(unlocked.ACH_BEAT_BURNS == true, "Burns achievement should unlock")
    assertTrue(unlocked.ACH_WIN_BY_COMMANDANT == true, "commandant achievement should unlock")
end)

runTest("achievement_defs_rating_updated_unlocks_field_marshal", function()
    resetModules()
    local unlocked = {}
    package.preload["steam_runtime"] = function()
        return {
            getAchievement = function()
                return false
            end,
            setAchievement = function(id)
                unlocked[id] = true
                return true
            end,
            storeUserStats = function()
                return true
            end
        }
    end

    local runtime = require("achievement_runtime")
    runtime.init()
    assertTrue(runtime.record("rating_updated", {rating = 1600}) == true, "rating_updated should be handled")
    assertTrue(unlocked.ACH_RATING_1600 == true, "1600 rating achievement should unlock")
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

print(string.format("achievement_runtime_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
