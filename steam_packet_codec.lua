local codec = {}

local DEFAULT_PROTOCOL_VERSION = ((SETTINGS or {}).STEAM_ONLINE or {}).PROTOCOL_VERSION or 1

local bitLib = nil
do
    local okBit, loadedBit = pcall(require, "bit")
    if okBit and loadedBit then
        bitLib = loadedBit
    else
        local okBit32, loadedBit32 = pcall(require, "bit32")
        if okBit32 and loadedBit32 then
            bitLib = loadedBit32
        end
    end
end

local function xor32(a, b)
    if bitLib and bitLib.bxor then
        return bitLib.bxor(a, b)
    end

    local result = 0
    local bitValue = 1
    local left = a
    local right = b

    while left > 0 or right > 0 do
        local leftBit = left % 2
        local rightBit = right % 2
        if leftBit ~= rightBit then
            result = result + bitValue
        end
        left = math.floor(left / 2)
        right = math.floor(right / 2)
        bitValue = bitValue * 2
    end

    return result
end

local function sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then
            return ta < tb
        end
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function encodeNumber(value)
    return string.format("%.17g", value)
end

local function encodeValue(value)
    local valueType = type(value)
    if value == nil then
        return "n"
    end
    if valueType == "boolean" then
        return value and "b1" or "b0"
    end
    if valueType == "number" then
        return "d" .. encodeNumber(value) .. ";"
    end
    if valueType == "string" then
        return "s" .. tostring(#value) .. ":" .. value
    end
    if valueType == "table" then
        local keys = sortedKeys(value)
        local parts = {"t", tostring(#keys), ":"}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = encodeValue(key)
            parts[#parts + 1] = encodeValue(value[key])
        end
        return table.concat(parts)
    end

    -- Fallback: deterministic string representation for unsupported types.
    local text = tostring(value)
    return "s" .. tostring(#text) .. ":" .. text
end

local function decodeValue(data, index)
    local tag = data:sub(index, index)
    if tag == "" then
        return nil, index, "unexpected_end"
    end

    if tag == "n" then
        return nil, index + 1, nil
    end

    if tag == "b" then
        local bit = data:sub(index + 1, index + 1)
        if bit == "1" then
            return true, index + 2, nil
        elseif bit == "0" then
            return false, index + 2, nil
        end
        return nil, index, "invalid_boolean"
    end

    if tag == "d" then
        local semicolon = data:find(";", index + 1, true)
        if not semicolon then
            return nil, index, "invalid_number"
        end
        local numberText = data:sub(index + 1, semicolon - 1)
        local numeric = tonumber(numberText)
        if numeric == nil then
            return nil, index, "invalid_number_value"
        end
        return numeric, semicolon + 1, nil
    end

    if tag == "s" then
        local colon = data:find(":", index + 1, true)
        if not colon then
            return nil, index, "invalid_string"
        end
        local lenText = data:sub(index + 1, colon - 1)
        local length = tonumber(lenText)
        if not length or length < 0 then
            return nil, index, "invalid_string_length"
        end
        local startPos = colon + 1
        local endPos = startPos + length - 1
        if endPos > #data then
            return nil, index, "string_out_of_bounds"
        end
        return data:sub(startPos, endPos), endPos + 1, nil
    end

    if tag == "t" then
        local colon = data:find(":", index + 1, true)
        if not colon then
            return nil, index, "invalid_table"
        end
        local countText = data:sub(index + 1, colon - 1)
        local count = tonumber(countText)
        if not count or count < 0 then
            return nil, index, "invalid_table_count"
        end
        local result = {}
        local cursor = colon + 1
        for _ = 1, count do
            local key, nextCursor, keyErr = decodeValue(data, cursor)
            if keyErr then
                return nil, index, keyErr
            end
            local value, valueCursor, valueErr = decodeValue(data, nextCursor)
            if valueErr then
                return nil, index, valueErr
            end
            result[key] = value
            cursor = valueCursor
        end
        return result, cursor, nil
    end

    return nil, index, "unknown_tag"
end

local function validatePacket(packet)
    if type(packet) ~= "table" then
        return false, "packet_not_table"
    end
    if type(packet.kind) ~= "string" or packet.kind == "" then
        return false, "packet_kind_missing"
    end
    return true
end

function codec.canonicalize(value)
    return encodeValue(value)
end

function codec.encode(packet, protocolVersion)
    local ok, err = validatePacket(packet)
    if not ok then
        return nil, err
    end
    local version = tonumber(protocolVersion) or DEFAULT_PROTOCOL_VERSION
    local payload = {
        version = version,
        packet = packet
    }
    return encodeValue(payload)
end

function codec.decode(raw, expectedProtocolVersion)
    if type(raw) ~= "string" or raw == "" then
        return nil, "packet_raw_missing"
    end

    local decoded, cursor, err = decodeValue(raw, 1)
    if err then
        return nil, err
    end
    if cursor <= #raw then
        return nil, "packet_trailing_data"
    end
    if type(decoded) ~= "table" then
        return nil, "packet_decoded_invalid"
    end

    local version = tonumber(decoded.version)
    if expectedProtocolVersion and version and version ~= expectedProtocolVersion then
        return nil, "protocol_mismatch"
    end

    local packet = decoded.packet
    local ok, validationErr = validatePacket(packet)
    if not ok then
        return nil, validationErr
    end

    return packet, nil
end

function codec.stateHashSignature(stateSignature)
    local canonical = codec.canonicalize(stateSignature or {})
    if love and love.data and love.data.hash then
        return love.data.hash("sha1", canonical)
    end

    local hash = 2166136261
    for i = 1, #canonical do
        hash = xor32(hash, canonical:byte(i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

return codec
