local fontCache = {}

local renderingQuality = require("rendering_quality")

local cache = {}
local DEFAULT_KEY = "__default__"

local function buildKey(path, size)
    return (path or DEFAULT_KEY) .. "|" .. tostring(size)
end

function fontCache.get(path, size)
    assert(type(size) == "number", "fontCache.get requires a numeric size")

    local resolvedPath = renderingQuality.fontCachePath(path)
    local key = buildKey(resolvedPath, size)
    local font = cache[key]

    if not font then
        font = renderingQuality.newFont(resolvedPath, size)
        cache[key] = font
    end

    return font
end

function fontCache.getDefault(size)
    return fontCache.get(nil, size)
end

return fontCache
