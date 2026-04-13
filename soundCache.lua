local soundCache = {}

local audioRuntime = require("audio_runtime")

local cache = {}

local function buildKey(path, sourceType)
    return tostring(path) .. "|" .. tostring(sourceType or "static")
end

function soundCache.get(path, sourceType)
    sourceType = sourceType or "static"
    local key = buildKey(path, sourceType)
    local source = cache[key]

    if not source then
        local ok, loadedSource = pcall(love.audio.newSource, path, sourceType)
        if not ok then
            return nil
        end
        source = loadedSource
        cache[key] = source
    end

    return source
end

function soundCache.clone(path, sourceType)
    local base = soundCache.get(path, sourceType)
    if not base then return nil end
    return base:clone()
end

local function applyOptions(source, opts)
    if not source or not opts then return end
    if opts.volume then
        source:setVolume(opts.volume)
    end
    if opts.pitch then
        source:setPitch(opts.pitch)
    end
end

function soundCache.play(path, opts)
    opts = opts or {}
    local sourceType = opts.type or "static"
    local useClone = opts.clone
    if useClone == nil then
        useClone = true
    end

    local source
    if useClone then
        source = soundCache.clone(path, sourceType)
        if not source then return nil end
        applyOptions(source, opts)
        source:play()
        audioRuntime.notePlayback(path, opts)
        return source
    end

    source = soundCache.get(path, sourceType)
    if not source then return nil end
    source:stop()
    source:seek(0)
    applyOptions(source, opts)
    source:play()
    audioRuntime.notePlayback(path, opts)
    return source
end

return soundCache
