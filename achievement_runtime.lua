local steamRuntime = require("steam_runtime")
local achievementDefs = require("achievement_defs")

local achievementRuntime = {}

local state = {
    initialized = false,
    unlocked = {},
    dirty = false,
    lastError = nil,
    lastFlushAt = nil
}

local function nowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

function achievementRuntime.init()
    state.initialized = true
end

function achievementRuntime.getDefinitions()
    return achievementDefs
end

function achievementRuntime.isUnlocked(id)
    local achievementId = tostring(id or "")
    if achievementId == "" then
        return false
    end

    if state.unlocked[achievementId] ~= nil then
        return state.unlocked[achievementId] == true
    end

    local unlocked, reason = steamRuntime.getAchievement(achievementId)
    if unlocked == nil then
        state.lastError = reason
        return false
    end

    state.unlocked[achievementId] = unlocked == true
    state.lastError = nil
    return state.unlocked[achievementId]
end

function achievementRuntime.unlock(id)
    local achievementId = tostring(id or "")
    if achievementId == "" then
        state.lastError = "achievement_id_missing"
        return false, state.lastError
    end

    if state.unlocked[achievementId] == true then
        return true, "already_unlocked"
    end

    local ok, reason = steamRuntime.setAchievement(achievementId)
    if ok ~= true then
        state.lastError = reason or "set_achievement_failed"
        return false, state.lastError
    end

    state.unlocked[achievementId] = true
    state.dirty = true
    state.lastError = nil
    return true
end

function achievementRuntime.record(eventName, payload)
    local handler = achievementDefs.EVENT_HANDLERS[tostring(eventName or "")]
    if type(handler) ~= "function" then
        return false, "no_handler"
    end
    return handler(achievementRuntime, payload)
end

function achievementRuntime.flush()
    if not state.dirty then
        return true, "noop"
    end

    local ok, reason = steamRuntime.storeUserStats()
    if ok ~= true then
        state.lastError = reason or "store_user_stats_failed"
        return false, state.lastError
    end

    state.dirty = false
    state.lastError = nil
    state.lastFlushAt = nowSeconds()
    return true
end

function achievementRuntime.getDiagnostics()
    local unlockedCount = 0
    for _, unlocked in pairs(state.unlocked) do
        if unlocked == true then
            unlockedCount = unlockedCount + 1
        end
    end

    return {
        initialized = state.initialized == true,
        dirty = state.dirty == true,
        unlockedCount = unlockedCount,
        lastError = state.lastError,
        lastFlushAt = state.lastFlushAt
    }
end

return achievementRuntime
