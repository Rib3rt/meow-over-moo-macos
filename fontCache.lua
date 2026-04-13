local fontCache = {}

local cache = {}
local DEFAULT_KEY = "__default__"

local function buildKey(path, size)
    return (path or DEFAULT_KEY) .. "|" .. tostring(size)
end

function fontCache.get(path, size)
    assert(type(size) == "number", "fontCache.get requires a numeric size")

    local key = buildKey(path, size)
    local font = cache[key]

    if not font then
        if path then
            font = love.graphics.newFont(path, size)
        else
            font = love.graphics.newFont(size)
        end
        cache[key] = font
    end

    return font
end

function fontCache.getDefault(size)
    return fontCache.get(nil, size)
end

return fontCache
