local resumeStore = {}

local FILE_NAME = "LastIncompleteMatch.dat"
local FORMAT_VERSION = 4

local MODE_ALLOWLIST = {
    ["singlePlayer"] = true,
    ["localMultyplayer"] = true
}

local function usingLoveFilesystem()
    return love
        and love.filesystem
        and type(love.filesystem.write) == "function"
        and type(love.filesystem.read) == "function"
end

local function resolvePath()
    if usingLoveFilesystem() and type(love.filesystem.getSaveDirectory) == "function" then
        local ok, saveDir = pcall(love.filesystem.getSaveDirectory)
        if ok and type(saveDir) == "string" and saveDir ~= "" then
            local normalized = saveDir:gsub("[/\\]+$", "")
            return normalized .. "/" .. FILE_NAME
        end
    end
    return FILE_NAME
end

local function readRaw()
    if usingLoveFilesystem() then
        local ok, content = pcall(love.filesystem.read, FILE_NAME)
        if ok and type(content) == "string" then
            return content
        end
        return nil, "missing"
    end

    local file, err = io.open(resolvePath(), "r")
    if not file then
        return nil, err or "missing"
    end

    local content = file:read("*a")
    file:close()
    return content
end

local function writeRaw(content)
    local resolved = resolvePath()

    -- Prefer atomic write (tmp + replace) to avoid partial snapshots on forced interrupts.
    local tmpPath = resolved .. ".tmp"
    local file, err = io.open(tmpPath, "w")
    if file then
        file:write(content)
        file:close()

        local renamed, renameErr = os.rename(tmpPath, resolved)
        if not renamed then
            os.remove(resolved)
            renamed, renameErr = os.rename(tmpPath, resolved)
        end
        if renamed then
            return true
        end
        os.remove(tmpPath)
        return false, renameErr or "rename_failed"
    end

    if usingLoveFilesystem() then
        local ok, writeErr = pcall(love.filesystem.write, FILE_NAME, content)
        if ok and writeErr == true then
            return true
        end
        if ok and type(writeErr) == "string" then
            return false, writeErr
        end
        if not ok then
            return false, writeErr
        end
        return false, err or "write_failed"
    end

    return false, err or "open_failed"
end

local function removeRaw()
    if usingLoveFilesystem() and type(love.filesystem.remove) == "function" then
        local ok, result = pcall(love.filesystem.remove, FILE_NAME)
        if ok then
            return result == true or result == nil
        end
        return false, result
    end

    local ok, err = os.remove(resolvePath())
    if ok == nil then
        if err and tostring(err):find("No such file", 1, true) then
            return true
        end
        return false, err
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
            if key > maxIndex then
                maxIndex = key
            end
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
            local keyExpr
            if isIdentifier(key) then
                keyExpr = key
            else
                keyExpr = "[" .. serializeValue(key, seen) .. "]"
            end
            parts[#parts + 1] = keyExpr .. "=" .. serializeValue(value[key], seen)
        end
    end

    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function encodeEnvelope(envelope)
    return "return " .. serializeValue(envelope, {}) .. "\n"
end

local function decodeEnvelope(content)
    if type(content) ~= "string" or content == "" then
        return nil, "empty"
    end

    local loader = loadstring or load
    local chunk, err
    if loader == load then
        chunk, err = loader(content, "@" .. FILE_NAME, "t", {})
    else
        chunk, err = loader(content, "@" .. FILE_NAME)
    end
    if not chunk then
        return nil, "decode_error:" .. tostring(err)
    end

    local ok, data = pcall(chunk)
    if not ok then
        return nil, "decode_runtime_error:" .. tostring(data)
    end

    if type(data) ~= "table" then
        return nil, "decoded_not_table"
    end

    return data
end

function resumeStore.isValidEnvelope(envelope)
    if type(envelope) ~= "table" then
        return false
    end

    if tonumber(envelope.version) ~= FORMAT_VERSION then
        return false
    end

    if not MODE_ALLOWLIST[tostring(envelope.mode or "")] then
        return false
    end

    if type(envelope.snapshot) ~= "table" then
        return false
    end

    return true
end

function resumeStore.save(envelope)
    if type(envelope) ~= "table" then
        return false, "invalid_envelope"
    end

    envelope.version = FORMAT_VERSION
    envelope.timestamp = envelope.timestamp or ((os and os.time and os.time()) or 0)

    if not resumeStore.isValidEnvelope(envelope) then
        return false, "invalid_envelope"
    end

    local payload = encodeEnvelope(envelope)
    return writeRaw(payload)
end

function resumeStore.load()
    local content, readErr = readRaw()
    if not content then
        return nil, readErr or "missing"
    end

    local envelope, decodeErr = decodeEnvelope(content)
    if not envelope then
        removeRaw()
        return nil, decodeErr
    end

    if not resumeStore.isValidEnvelope(envelope) then
        removeRaw()
        return nil, "invalid_envelope"
    end

    return envelope
end

function resumeStore.clear(reason)
    local ok, err = removeRaw()
    if not ok then
        return false, err
    end
    return true
end

function resumeStore.hasMatchingMode(mode)
    if not MODE_ALLOWLIST[tostring(mode or "")] then
        return false
    end

    local envelope = resumeStore.load()
    if not envelope then
        return false
    end

    return tostring(envelope.mode) == tostring(mode)
end

function resumeStore.getPath()
    return resolvePath()
end

return resumeStore
