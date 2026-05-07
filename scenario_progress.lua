local scenarioProgress = {}

local PROGRESS_FILE = "ScenarioProgress.dat"
local PROGRESS_VERSION = 1

local runtimeProgressData = {
    version = PROGRESS_VERSION,
    scenarios = {}
}

local function usingLoveFilesystem()
    return love
        and love.filesystem
        and type(love.filesystem.write) == "function"
        and type(love.filesystem.read) == "function"
end

local function resolveStoragePath()
    if usingLoveFilesystem() and type(love.filesystem.getSaveDirectory) == "function" then
        local ok, saveDir = pcall(love.filesystem.getSaveDirectory)
        if ok and type(saveDir) == "string" and saveDir ~= "" then
            local normalized = saveDir:gsub("[/\\]+$", "")
            return normalized .. "/" .. PROGRESS_FILE
        end
    end
    return PROGRESS_FILE
end

local function readRawProgress()
    if usingLoveFilesystem() then
        local ok, content = pcall(love.filesystem.read, PROGRESS_FILE)
        if ok and type(content) == "string" then
            return content
        end
        return nil
    end

    local file = io.open(resolveStoragePath(), "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function writeRawProgress(content)
    if usingLoveFilesystem() then
        local ok, result = pcall(love.filesystem.write, PROGRESS_FILE, content)
        return ok and result == true
    end

    local path = resolveStoragePath()
    local tmpPath = path .. ".tmp"
    local file = io.open(tmpPath, "w")
    if not file then
        return false
    end
    file:write(content)
    file:close()

    local renamed = os.rename(tmpPath, path)
    if not renamed then
        os.remove(path)
        renamed = os.rename(tmpPath, path)
    end
    if not renamed then
        os.remove(tmpPath)
        return false
    end
    return true
end

local function sortKeys(keys)
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == tb then
            if ta == "number" then
                return a < b
            end
            return tostring(a) < tostring(b)
        end
        return ta < tb
    end)
end

local function isIdentifier(str)
    return type(str) == "string" and str:match("^[%a_][%w_]*$") ~= nil
end

local function serializeValue(value, seen)
    local valueType = type(value)
    if valueType == "nil" then
        return "nil"
    end
    if valueType == "boolean" then
        return value and "true" or "false"
    end
    if valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "0"
        end
        return tostring(value)
    end
    if valueType == "string" then
        return string.format("%q", value)
    end
    if valueType ~= "table" then
        return "nil"
    end

    if seen[value] then
        return "nil"
    end
    seen[value] = true

    local isArray = true
    local maxIndex = 0
    for key, _ in pairs(value) do
        if type(key) == "number" and key >= 1 and math.floor(key) == key then
            maxIndex = math.max(maxIndex, key)
        else
            isArray = false
            break
        end
    end

    if isArray then
        for i = 1, maxIndex do
            if value[i] == nil then
                isArray = false
                break
            end
        end
    end

    local parts = {}
    if isArray then
        for i = 1, maxIndex do
            parts[#parts + 1] = serializeValue(value[i], seen)
        end
    else
        local keys = {}
        for key, _ in pairs(value) do
            keys[#keys + 1] = key
        end
        sortKeys(keys)
        for _, key in ipairs(keys) do
            local keyExpr = isIdentifier(key) and key or ("[" .. serializeValue(key, seen) .. "]")
            parts[#parts + 1] = keyExpr .. "=" .. serializeValue(value[key], seen)
        end
    end

    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function encodeProgress(data)
    return "return " .. serializeValue(data, {}) .. "\n"
end

local function decodeProgress(content)
    if type(content) ~= "string" or content == "" then
        return nil
    end

    local loader = loadstring or load
    local chunk
    if loader == load then
        chunk = loader(content, "@" .. PROGRESS_FILE, "t", {})
    else
        chunk = loader(content, "@" .. PROGRESS_FILE)
    end
    if not chunk then
        return nil
    end

    local ok, value = pcall(chunk)
    if not ok or type(value) ~= "table" then
        return nil
    end
    return value
end

local function normalizeData(data)
    data = type(data) == "table" and data or {
        version = PROGRESS_VERSION,
        scenarios = {}
    }
    data.version = PROGRESS_VERSION
    data.scenarios = type(data.scenarios) == "table" and data.scenarios or {}
    return data
end

function scenarioProgress.load()
    local rawProgress = readRawProgress()
    runtimeProgressData = normalizeData(decodeProgress(rawProgress))
    return runtimeProgressData
end

function scenarioProgress.save(data)
    runtimeProgressData = normalizeData(data)
    return writeRawProgress(encodeProgress(runtimeProgressData))
end

function scenarioProgress.getEntry(data, scenarioId)
    data = normalizeData(data or scenarioProgress.load())
    local key = tostring(scenarioId or "")
    local entry = data.scenarios[key]
    if type(entry) ~= "table" then
        entry = { attempts = 0, solved = false }
        data.scenarios[key] = entry
    end
    entry.attempts = math.max(0, tonumber(entry.attempts) or 0)
    entry.solved = entry.solved == true
    return entry
end

function scenarioProgress.applyResult(result)
    if type(result) ~= "table" then
        return nil
    end

    local scenarioId = tostring(result.id or "")
    if scenarioId == "" then
        return nil
    end

    local data = scenarioProgress.load()
    local entry = scenarioProgress.getEntry(data, scenarioId)
    local solved = result.solved == true
    entry.solved = entry.solved == true or solved

    local attempts = tonumber(result.attempts)
    if attempts then
        entry.attempts = math.max(entry.attempts or 0, math.max(0, math.floor(attempts)))
    end

    scenarioProgress.save(data)
    return solved
end

function scenarioProgress.path()
    return resolveStoragePath()
end

return scenarioProgress
