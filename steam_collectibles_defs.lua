local collectiblesDefs = {
    VERSION = 1,
    DEFAULT_BADGE_SERIES = 1,
    BADGES = {
        standard = {
            id = "standard",
            series = 1,
            foil = false,
            label = "Standard Badge"
        },
        foil = {
            id = "foil",
            series = 1,
            foil = true,
            label = "Foil Badge"
        }
    }
}

return collectiblesDefs
