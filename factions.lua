local Factions = {}

local FACTION_LIST = {
    {
        id = 1,
        key = "cats",
        name = "Meow Alliance",
        shortName = "Cats",
        description = "Blu faction will do the first move.",
        color = {0.15, 0.35, 0.9},
        accentColor = {0.35, 0.65, 1.0},
        supplyPanelTitle = "CAT SUPPLY",
        turnOrder = 1,
        cardAssets = {
            imagePath = "assets/sprites/Blu_Simple.png",
            templateTint = {0.2, 0.4, 0.8, 0.8}
        }
    },
    {
        id = 2,
        key = "cows",
        name = "Moo Dominion",
        shortName = "Cows",
        description = "",
        color = {0.75, 0.2, 0.2},
        accentColor = {1.0, 0.45, 0.35},
        supplyPanelTitle = "COW SUPPLY",
        turnOrder = 2,
        cardAssets = {
            imagePath = "assets/sprites/Red_Simple.png",
            templateTint = {0.85, 0.3, 0.25, 0.8}
        }
    }
}

local BY_ID = {}
local BY_KEY = {}

for _, faction in ipairs(FACTION_LIST) do
    BY_ID[faction.id] = faction
    if faction.key then
        BY_KEY[faction.key] = faction
    end
end

function Factions.getAll()
    return FACTION_LIST
end

function Factions.getById(id)
    return BY_ID[id]
end

function Factions.getByKey(key)
    if not key then
        return nil
    end
    return BY_KEY[key]
end

function Factions.count()
    return #FACTION_LIST
end

function Factions.getTurnOrder()
    return {1, 2}
end

return Factions
