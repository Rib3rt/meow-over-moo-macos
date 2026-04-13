local logger = {}

local LEVELS = {
    off = 0,
    error = 1,
    warn = 2,
    info = 3,
    debug = 4
}

local PREFIX = {
    error = "[ERROR]",
    warn = "[WARN]",
    info = "[INFO]",
    debug = "[DEBUG]"
}

local function getPerfConfig()
    local settings = SETTINGS or {}
    return settings.PERF or {}
end

local function normalizeLevel(level)
    return tostring(level or "warn"):lower()
end

local function currentLevelValue()
    local config = getPerfConfig()
    local levelName = normalizeLevel(config.LOG_LEVEL)
    return LEVELS[levelName] or LEVELS.warn
end

local function categoryEnabled(category)
    if not category or category == "" then
        return false
    end

    local config = getPerfConfig()
    local categories = config.LOG_CATEGORIES or {}
    return categories[category] == true
end

function logger.isEnabled(level, category)
    local levelName = normalizeLevel(level)

    -- Error logs stay available regardless of LOG_LEVEL/category gates.
    if levelName == "error" then
        return true
    end

    local levelValue = LEVELS[levelName] or LEVELS.warn
    if currentLevelValue() < levelValue then
        return false
    end

    if levelName == "warn" then
        return true
    end

    return categoryEnabled(category)
end

local function emit(level, category, ...)
    if not logger.isEnabled(level, category) then
        return
    end

    local prefix = PREFIX[level] or "[LOG]"
    if category and category ~= "" then
        prefix = prefix .. "[" .. tostring(category) .. "]"
    end

    if select("#", ...) > 0 then
        print(prefix, ...)
    else
        print(prefix)
    end
end

function logger.debug(category, ...)
    emit("debug", category, ...)
end

function logger.info(category, ...)
    emit("info", category, ...)
end

function logger.warn(category, ...)
    emit("warn", category, ...)
end

function logger.error(category, ...)
    emit("error", category, ...)
end

return logger
