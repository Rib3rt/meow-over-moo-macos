local inputBackend = {}

local STEAM_INPUT_STATE_NAMES = {
    mainMenu = true,
    factionSelect = true,
    gameplay = true,
    onlineLobby = true,
    onlineLeaderboard = true,
}

function inputBackend.isSteamInputEligibleState(stateName)
    return STEAM_INPUT_STATE_NAMES[tostring(stateName or "")] == true
end

function inputBackend.shouldUseSteamInputBackend(stateName, steamRuntime)
    if not inputBackend.isSteamInputEligibleState(stateName) then
        return false
    end
    if not steamRuntime or type(steamRuntime.isOnlineReady) ~= "function" or steamRuntime.isOnlineReady() ~= true then
        return false
    end
    if type(steamRuntime.configureSteamInput) ~= "function" or type(steamRuntime.pollSteamInputActions) ~= "function" then
        return false
    end
    return true
end

return inputBackend
