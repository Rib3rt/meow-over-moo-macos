local achievementDefs = {
    VERSION = 2,
    ACHIEVEMENTS = {
        ACH_FIRST_ORDERS = { displayName = "First Orders" },
        ACH_BEAT_BURT = { displayName = "Burt, Beaten" },
        ACH_BEAT_BURNS = { displayName = "Burns Down" },
        ACH_BEAT_MARGE = { displayName = "Marge Overruled" },
        ACH_BEAT_HOMER = { displayName = "Homer Defeated" },
        ACH_BEAT_MAGGIE = { displayName = "Maggie Outplayed" },
        ACH_BEAT_LISA = { displayName = "Lisa Outmaneuvered" },
        ACH_PLAY_LOCAL = { displayName = "Couch Commander" },
        ACH_PLAY_ONLINE = { displayName = "Connected Forces" },
        ACH_WIN_ONLINE = { displayName = "Network Victory" },
        ACH_WIN_BY_COMMANDANT = { displayName = "Decapitation Strike" },
        ACH_WIN_BY_ELIMINATION = { displayName = "Total Annihilation" },
        ACH_RATING_1600 = { displayName = "Field Marshal" }
    },
    STATS = {
        ONLINE_MATCHES_PLAYED = "STAT_ONLINE_MATCHES_PLAYED",
        ONLINE_MATCHES_WON = "STAT_ONLINE_MATCHES_WON",
        LOCAL_MATCHES_PLAYED = "STAT_LOCAL_MATCHES_PLAYED",
        AI_MATCHES_WON = "STAT_AI_MATCHES_WON",
        CURRENT_RATING = "STAT_CURRENT_RATING",
        HIGHEST_RATING = "STAT_HIGHEST_RATING"
    },
    EVENT_HANDLERS = {}
}

local function normalizeName(value)
    local text = tostring(value or "")
    text = text:gsub("%s*%b()", "")
    text = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

local function unlockIfNeeded(runtime, id)
    if not id then
        return true
    end
    return runtime.unlock(id) == true
end

local AI_VICTORY_ACHIEVEMENTS = {
    burt = "ACH_BEAT_BURT",
    burns = "ACH_BEAT_BURNS",
    marge = "ACH_BEAT_MARGE",
    homer = "ACH_BEAT_HOMER",
    maggie = "ACH_BEAT_MAGGIE",
    lisa = "ACH_BEAT_LISA"
}

achievementDefs.EVENT_HANDLERS.gameplay_started = function(runtime, payload)
    unlockIfNeeded(runtime, "ACH_FIRST_ORDERS")

    if payload and payload.resumed == true then
        return true
    end

    local mode = tostring(payload and payload.mode or "")
    if mode == "localMultyplayer" then
        unlockIfNeeded(runtime, "ACH_PLAY_LOCAL")
    elseif mode == "onlineMultyplayer" then
        unlockIfNeeded(runtime, "ACH_PLAY_ONLINE")
    end

    return true
end

achievementDefs.EVENT_HANDLERS.match_completed = function(runtime, payload)
    payload = type(payload) == "table" and payload or {}
    if payload.localUserWon ~= true then
        return true
    end

    local mode = tostring(payload.mode or "")
    if mode == "onlineMultyplayer" then
        unlockIfNeeded(runtime, "ACH_WIN_ONLINE")
    end

    local victoryReason = tostring(payload.victoryReason or "")
    if victoryReason == "commandant" then
        unlockIfNeeded(runtime, "ACH_WIN_BY_COMMANDANT")
    elseif victoryReason == "elimination" then
        unlockIfNeeded(runtime, "ACH_WIN_BY_ELIMINATION")
    end

    if mode == "singlePlayer" and tostring(payload.opponentControllerType or "") == "ai" then
        local opponentKey = normalizeName(payload.opponentControllerNickname)
        unlockIfNeeded(runtime, AI_VICTORY_ACHIEVEMENTS[opponentKey])
    end

    return true
end

achievementDefs.EVENT_HANDLERS.rating_updated = function(runtime, payload)
    local rating = tonumber(payload and payload.rating)
    if rating and rating >= 1600 then
        unlockIfNeeded(runtime, "ACH_RATING_1600")
    end
    return true
end

return achievementDefs
