local glicko2 = require("glicko2_rating")
local steamRuntime = require("steam_runtime")
local achievementDefs = require("achievement_defs")

local ratingStore = {}

local FORMAT_VERSION = 2
local MAGIC = "MOMRP2\0"
local PRIMARY_FILE_NAME = (((SETTINGS or {}).RATING or (SETTINGS or {}).ELO or {}).PROFILE_FILE) or "OnlineRatingProfile.dat"
local BACKUP_FILE_NAME = PRIMARY_FILE_NAME:gsub("%.dat$", "") .. ".bak"
local TMP_FILE_NAME = PRIMARY_FILE_NAME .. ".tmp"
local REPAIR_NOTICE_TITLE = "Rating Profile Repaired"
local REPAIR_NOTICE_TEXT = "Online rating data could not be verified and was safely repaired."

local state = {
    cache = nil,
    cacheEnvelope = nil,
    cacheSource = nil,
    repairNoticePending = false,
    repairNoticeShown = false
}

local function nowSeconds()
    if love and love.timer and love.timer.getTime then
        return math.floor(love.timer.getTime())
    end
    if os and os.time then
        return math.floor(os.time())
    end
    return 0
end

local function clone(value)
    if type(value) ~= "table" then
        return value
    end
    local copied = {}
    for key, inner in pairs(value) do
        copied[key] = clone(inner)
    end
    return copied
end

local function usingLoveFilesystem()
    return love
        and love.filesystem
        and type(love.filesystem.read) == "function"
        and type(love.filesystem.write) == "function"
end

local function resolvePath(fileName)
    if usingLoveFilesystem() and type(love.filesystem.getSaveDirectory) == "function" then
        local ok, saveDir = pcall(love.filesystem.getSaveDirectory)
        if ok and type(saveDir) == "string" and saveDir ~= "" then
            local normalized = saveDir:gsub("[/\\]+$", "")
            return normalized .. "/" .. tostring(fileName)
        end
    end
    return tostring(fileName)
end

local function readRawFile(fileName)
    if usingLoveFilesystem() then
        local ok, content = pcall(love.filesystem.read, fileName)
        if ok and type(content) == "string" then
            return content
        end
        return nil, "missing"
    end

    local file, err = io.open(resolvePath(fileName), "rb")
    if not file then
        return nil, err or "missing"
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function writeRawFile(fileName, content)
    if usingLoveFilesystem() then
        local ok, result = pcall(love.filesystem.write, fileName, content)
        if ok and result == true then
            return true
        end
        if ok and type(result) == "string" then
            return false, result
        end
        return false, result or "write_failed"
    end

    local file, err = io.open(resolvePath(fileName), "wb")
    if not file then
        return false, err or "open_failed"
    end
    file:write(content)
    file:close()
    return true
end

local function removeRawFile(fileName)
    if usingLoveFilesystem() and type(love.filesystem.remove) == "function" then
        local ok, result = pcall(love.filesystem.remove, fileName)
        if ok then
            return result == true or result == nil
        end
        return false, result
    end

    local ok, err = os.remove(resolvePath(fileName))
    if ok == nil and err and tostring(err):find("No such file", 1, true) then
        return true
    end
    return ok ~= nil
end

local function fileExists(fileName)
    local content = readRawFile(fileName)
    return type(content) == "string"
end

local function copyRawFile(sourceName, destinationName)
    local content = readRawFile(sourceName)
    if not content then
        return false
    end
    local ok = writeRawFile(destinationName, content)
    return ok == true
end

local function packU32LE(value)
    local normalized = math.max(0, math.floor(tonumber(value) or 0))
    local b1 = normalized % 256
    normalized = math.floor(normalized / 256)
    local b2 = normalized % 256
    normalized = math.floor(normalized / 256)
    local b3 = normalized % 256
    normalized = math.floor(normalized / 256)
    local b4 = normalized % 256
    return string.char(b1, b2, b3, b4)
end

local function unpackU32LE(content, offset)
    offset = math.max(1, math.floor(offset or 1))
    local b1, b2, b3, b4 = content:byte(offset, offset + 3)
    if not b4 then
        return nil, "u32_out_of_bounds"
    end
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216, offset + 4
end

local function xorShiftBytes(content, decode)
    local bytes = {}
    for index = 1, #content do
        local source = content:byte(index)
        local shift = ((index * 37) + 91) % 251
        local value
        if decode then
            value = (source - shift) % 256
        else
            value = (source + shift) % 256
        end
        bytes[index] = string.char(value)
    end
    return table.concat(bytes)
end

local function encodeNumber(value)
    local number = tonumber(value) or 0
    local text = string.format("%.10f", number)
    text = text:gsub("0+$", "")
    text = text:gsub("%.$", "")
    if text == "" or text == "-0" then
        return "0"
    end
    return text
end

local function encodeInteger(value)
    return tostring(math.floor(tonumber(value) or 0))
end

local function encodeBoolean(value)
    return value == true and "1" or "0"
end

local function decodeBoolean(value)
    return tostring(value or "0") == "1"
end

local function currentAppId()
    return tostring((((SETTINGS or {}).STEAM or {}).APP_ID) or "")
end

local function currentOwnerSteamId()
    local getLocalUserId = steamRuntime and steamRuntime.getLocalUserId
    local userId = type(getLocalUserId) == "function" and getLocalUserId() or nil
    if type(userId) == "string" and userId ~= "" then
        return userId
    end
    return "offline"
end

local function computeLuaSignature(canonicalPayload, ownerSteamId, appId)
    local combined = table.concat({
        "MOM_RATING_PROFILE_V2",
        tostring(ownerSteamId or ""),
        tostring(appId or ""),
        tostring(canonicalPayload or "")
    }, "\n")

    local hashA = 1573941
    local hashB = 4511981
    for index = 1, #combined do
        local byte = combined:byte(index)
        hashA = ((hashA * 131) + byte + 17 + (index % 23)) % 2147483647
        hashB = ((hashB * 257) + byte + 29 + (index % 31)) % 2147483647
    end

    return string.format("L1:%08x%08x", hashA, hashB)
end

local function computeSignature(canonicalPayload, ownerSteamId, appId, mode)
    if steamRuntime and type(steamRuntime.computeRatingProfileSignature) == "function" then
        local token, reason = steamRuntime.computeRatingProfileSignature(canonicalPayload, ownerSteamId, appId, mode)
        if type(token) == "string" and token ~= "" then
            return token
        end
        if mode == "native_only" then
            return nil, reason or "native_signature_unavailable"
        end
    elseif mode == "native_only" then
        return nil, "native_signature_unavailable"
    end

    if mode == "native_only" then
        return nil, "native_signature_unavailable"
    end

    return computeLuaSignature(canonicalPayload, ownerSteamId, appId)
end

local function sanitizeProfile(profile)
    return glicko2.sanitizeProfile(profile)
end

local function currentDay()
    return glicko2.currentDay()
end

local function integerMirror(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function fetchLiveMirrors()
    if not steamRuntime or type(steamRuntime.getStatInt) ~= "function" then
        return nil, "steam_stats_unavailable"
    end

    local stats = (achievementDefs and achievementDefs.STATS) or {}
    local currentRating = steamRuntime.getStatInt(stats.CURRENT_RATING)
    local highestRating = steamRuntime.getStatInt(stats.HIGHEST_RATING)
    local matchesPlayed = steamRuntime.getStatInt(stats.ONLINE_MATCHES_PLAYED)
    local matchesWon = steamRuntime.getStatInt(stats.ONLINE_MATCHES_WON)

    if currentRating == nil or highestRating == nil or matchesPlayed == nil or matchesWon == nil then
        return nil, "steam_stats_unavailable"
    end

    return {
        currentRating = integerMirror(currentRating),
        highestRating = integerMirror(highestRating),
        onlineMatchesPlayed = integerMirror(matchesPlayed),
        onlineMatchesWon = integerMirror(matchesWon)
    }
end

local function normalizeMirrors(mirrors, profile, fallback)
    mirrors = type(mirrors) == "table" and clone(mirrors) or {}
    fallback = type(fallback) == "table" and fallback or {}
    profile = sanitizeProfile(profile)

    local currentRating = integerMirror(mirrors.currentRating)
    if currentRating == 0 then
        currentRating = math.floor((tonumber(profile.rating) or 0) + 0.5)
    end

    local highestRating = integerMirror(mirrors.highestRating)
    if highestRating == 0 then
        highestRating = integerMirror(fallback.highestRating)
    end
    highestRating = math.max(highestRating, currentRating)

    local onlineMatchesPlayed = integerMirror(mirrors.onlineMatchesPlayed)
    if onlineMatchesPlayed == 0 then
        onlineMatchesPlayed = math.max(integerMirror(fallback.onlineMatchesPlayed), integerMirror(profile.games))
    end

    local onlineMatchesWon = integerMirror(mirrors.onlineMatchesWon)
    if onlineMatchesWon == 0 and integerMirror(fallback.onlineMatchesWon) > 0 then
        onlineMatchesWon = integerMirror(fallback.onlineMatchesWon)
    end
    onlineMatchesWon = math.max(0, math.min(onlineMatchesWon, onlineMatchesPlayed))

    return {
        currentRating = currentRating,
        highestRating = highestRating,
        onlineMatchesPlayed = onlineMatchesPlayed,
        onlineMatchesWon = onlineMatchesWon
    }
end

local function canonicalizeEnvelope(envelope)
    local profile = sanitizeProfile(envelope.profile)
    local mirrors = normalizeMirrors(envelope.mirrors, profile)
    local lines = {
        "version=" .. encodeInteger(envelope.version),
        "ownerSteamId=" .. tostring(envelope.ownerSteamId or ""),
        "appId=" .. tostring(envelope.appId or ""),
        "revision=" .. encodeInteger(envelope.revision),
        "savedAt=" .. encodeInteger(envelope.savedAt),
        "profile.rating=" .. encodeNumber(profile.rating),
        "profile.rd=" .. encodeNumber(profile.rd),
        "profile.vol=" .. encodeNumber(profile.vol),
        "profile.games=" .. encodeInteger(profile.games),
        "profile.lastPeriodDay=" .. encodeInteger(profile.lastPeriodDay),
        "profile.lastOpponentHash=" .. encodeInteger(profile.lastOpponentHash),
        "profile.sameOpponentStreak=" .. encodeInteger(profile.sameOpponentStreak),
        "profile.lastRankedDay=" .. encodeInteger(profile.lastRankedDay),
        "profile.seededFromLeaderboard=" .. encodeBoolean(profile.seededFromLeaderboard),
        "mirrors.currentRating=" .. encodeInteger(mirrors.currentRating),
        "mirrors.highestRating=" .. encodeInteger(mirrors.highestRating),
        "mirrors.onlineMatchesPlayed=" .. encodeInteger(mirrors.onlineMatchesPlayed),
        "mirrors.onlineMatchesWon=" .. encodeInteger(mirrors.onlineMatchesWon)
    }
    return table.concat(lines, "\n") .. "\n"
end

local function parseCanonicalPayload(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil, "payload_empty"
    end

    local entries = {}
    for line in payload:gmatch("[^\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
            entries[key] = value
        end
    end

    if tonumber(entries.version) ~= FORMAT_VERSION then
        return nil, "payload_version_invalid"
    end

    local envelope = {
        version = tonumber(entries.version),
        ownerSteamId = tostring(entries.ownerSteamId or ""),
        appId = tostring(entries.appId or ""),
        revision = math.floor(tonumber(entries.revision) or 0),
        savedAt = math.floor(tonumber(entries.savedAt) or 0),
        profile = {
            rating = tonumber(entries["profile.rating"]),
            rd = tonumber(entries["profile.rd"]),
            vol = tonumber(entries["profile.vol"]),
            games = tonumber(entries["profile.games"]),
            lastPeriodDay = tonumber(entries["profile.lastPeriodDay"]),
            lastOpponentHash = tonumber(entries["profile.lastOpponentHash"]),
            sameOpponentStreak = tonumber(entries["profile.sameOpponentStreak"]),
            lastRankedDay = tonumber(entries["profile.lastRankedDay"]),
            seededFromLeaderboard = decodeBoolean(entries["profile.seededFromLeaderboard"])
        },
        mirrors = {
            currentRating = tonumber(entries["mirrors.currentRating"]),
            highestRating = tonumber(entries["mirrors.highestRating"]),
            onlineMatchesPlayed = tonumber(entries["mirrors.onlineMatchesPlayed"]),
            onlineMatchesWon = tonumber(entries["mirrors.onlineMatchesWon"])
        }
    }

    return envelope
end

local function decodeLegacyScalar(raw)
    local value = tostring(raw or "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "true" then
        return true
    elseif value == "false" then
        return false
    elseif value == "nil" or value == "" then
        return nil
    end
    local number = tonumber(value)
    if number ~= nil then
        return number
    end
    local quoted = value:match('^"(.*)"$')
    if quoted then
        return quoted:gsub('\\"', '"')
    end
    return value
end

local function decodeLegacyEnvelope(content)
    if type(content) ~= "string" or content == "" then
        return nil, "legacy_empty"
    end

    local version = tonumber(content:match("version%s*=%s*(%d+)")) or 1
    if version ~= 1 then
        return nil, "legacy_version_invalid"
    end

    local profileBody = content:match("profile%s*=%s*(%b{})")
    if not profileBody then
        return nil, "legacy_profile_missing"
    end

    local profile = {}
    for key, rawValue in profileBody:gmatch("([%w_]+)%s*=%s*([^,%}]+)") do
        profile[key] = decodeLegacyScalar(rawValue)
    end

    return {
        version = 1,
        profile = sanitizeProfile(profile)
    }
end

local function encodeV2Envelope(envelope)
    local canonicalPayload = canonicalizeEnvelope(envelope)
    local signature, signatureErr = computeSignature(canonicalPayload, envelope.ownerSteamId, envelope.appId)
    if not signature then
        return nil, signatureErr or "signature_failed"
    end

    local payloadBytes = xorShiftBytes(canonicalPayload, false)
    local data = table.concat({
        MAGIC,
        packU32LE(#signature),
        packU32LE(#payloadBytes),
        signature,
        payloadBytes
    })

    local written = clone(envelope)
    written.profile = sanitizeProfile(envelope.profile)
    written.mirrors = normalizeMirrors(envelope.mirrors, written.profile)
    written.signature = signature
    written.canonicalPayload = canonicalPayload
    written.raw = data
    return written
end

local function decodeV2Envelope(content)
    if type(content) ~= "string" or #content < (#MAGIC + 8) then
        return nil, "v2_too_short"
    end
    if content:sub(1, #MAGIC) ~= MAGIC then
        return nil, "v2_magic_missing"
    end

    local offset = #MAGIC + 1
    local signatureLength
    signatureLength, offset = unpackU32LE(content, offset)
    if not signatureLength then
        return nil, "v2_signature_length_missing"
    end
    local payloadLength
    payloadLength, offset = unpackU32LE(content, offset)
    if not payloadLength then
        return nil, "v2_payload_length_missing"
    end

    local expectedLength = (#MAGIC + 8 + signatureLength + payloadLength)
    if #content ~= expectedLength then
        return nil, "v2_length_mismatch"
    end

    local signature = content:sub(offset, offset + signatureLength - 1)
    local payloadBytes = content:sub(offset + signatureLength, offset + signatureLength + payloadLength - 1)
    local canonicalPayload = xorShiftBytes(payloadBytes, true)
    local envelope, err = parseCanonicalPayload(canonicalPayload)
    if not envelope then
        return nil, err or "v2_payload_invalid"
    end

    envelope.signature = signature
    envelope.canonicalPayload = canonicalPayload
    envelope.raw = content
    return envelope
end

local function validateMirrors(mirrors, profile)
    local normalized = normalizeMirrors(mirrors, profile)
    if normalized.highestRating < normalized.currentRating then
        return nil, "mirrors_highest_below_current"
    end
    if normalized.onlineMatchesWon > normalized.onlineMatchesPlayed then
        return nil, "mirrors_wins_exceed_matches"
    end
    if normalized.onlineMatchesPlayed < integerMirror(profile.games) then
        return nil, "mirrors_matches_below_games"
    end
    return normalized
end

local function validateEnvelope(envelope, opts)
    opts = opts or {}
    if type(envelope) ~= "table" then
        return nil, "envelope_missing"
    end
    if tonumber(envelope.version) ~= FORMAT_VERSION then
        return nil, "envelope_version_invalid"
    end

    local ownerSteamId = tostring(envelope.ownerSteamId or "")
    local appId = tostring(envelope.appId or "")
    local expectedOwner = tostring(opts.ownerSteamId or currentOwnerSteamId())
    local expectedAppId = tostring(opts.appId or currentAppId())
    if ownerSteamId == "" or ownerSteamId ~= expectedOwner then
        return nil, "owner_mismatch"
    end
    if appId == "" or appId ~= expectedAppId then
        return nil, "app_id_mismatch"
    end

    local revision = math.floor(tonumber(envelope.revision) or -1)
    if revision < 0 or revision > 2147483647 then
        return nil, "revision_invalid"
    end

    local savedAt = math.floor(tonumber(envelope.savedAt) or -1)
    local now = nowSeconds()
    if savedAt < 0 or savedAt > (now + 31536000) then
        return nil, "saved_at_invalid"
    end

    local profile, profileErr = glicko2.validateProfile(envelope.profile, currentDay())
    if not profile then
        return nil, profileErr or "profile_invalid"
    end

    if revision > 0 and savedAt > 0 and profile.lastPeriodDay > (currentDay() + 366) then
        return nil, "profile_day_regression"
    end

    local mirrors, mirrorErr = validateMirrors(envelope.mirrors, profile)
    if not mirrors then
        return nil, mirrorErr or "mirrors_invalid"
    end

    local canonicalPayload = canonicalizeEnvelope({
        version = FORMAT_VERSION,
        ownerSteamId = ownerSteamId,
        appId = appId,
        revision = revision,
        savedAt = savedAt,
        profile = profile,
        mirrors = mirrors
    })

    local signatureMode = nil
    local signature = tostring(envelope.signature or "")
    if signature:match("^N1:") then
        signatureMode = "native_only"
    elseif signature:match("^L1:") then
        signatureMode = "fallback_only"
    else
        return nil, "signature_prefix_invalid"
    end

    local expectedSignature, signatureErr = computeSignature(canonicalPayload, ownerSteamId, appId, signatureMode)
    if not expectedSignature or expectedSignature ~= signature then
        return nil, signatureErr or "signature_mismatch"
    end

    local liveMirrors = opts.liveMirrors or fetchLiveMirrors()
    if liveMirrors then
        if math.abs(integerMirror(liveMirrors.currentRating) - integerMirror(mirrors.currentRating)) > 1 then
            return nil, "live_stat_current_rating_mismatch"
        end
        if math.abs(integerMirror(liveMirrors.highestRating) - integerMirror(mirrors.highestRating)) > 1 then
            return nil, "live_stat_highest_rating_mismatch"
        end
        if integerMirror(liveMirrors.onlineMatchesPlayed) ~= integerMirror(mirrors.onlineMatchesPlayed) then
            return nil, "live_stat_matches_mismatch"
        end
        if integerMirror(liveMirrors.onlineMatchesWon) ~= integerMirror(mirrors.onlineMatchesWon) then
            return nil, "live_stat_wins_mismatch"
        end
    end

    return {
        version = FORMAT_VERSION,
        ownerSteamId = ownerSteamId,
        appId = appId,
        revision = revision,
        savedAt = savedAt,
        profile = profile,
        mirrors = mirrors,
        signature = signature,
        canonicalPayload = canonicalPayload,
        raw = envelope.raw
    }
end

local function buildEnvelope(profile, opts)
    opts = opts or {}
    local normalizedProfile = sanitizeProfile(profile)
    local previousMirrors = opts.previousMirrors or (state.cacheEnvelope and state.cacheEnvelope.mirrors) or nil
    local liveMirrors = opts.liveMirrors or fetchLiveMirrors()
    local mirrors = normalizeMirrors(liveMirrors, normalizedProfile, previousMirrors)
    return {
        version = FORMAT_VERSION,
        ownerSteamId = tostring(opts.ownerSteamId or currentOwnerSteamId()),
        appId = tostring(opts.appId or currentAppId()),
        revision = math.max(0, math.floor(tonumber(opts.revision) or (((state.cacheEnvelope and state.cacheEnvelope.revision) or 0) + 1))),
        savedAt = math.max(0, math.floor(tonumber(opts.savedAt) or nowSeconds())),
        profile = normalizedProfile,
        mirrors = mirrors
    }
end

local function persistEnvelope(envelope, opts)
    opts = opts or {}
    local encodedEnvelope, encodeErr = encodeV2Envelope(envelope)
    if not encodedEnvelope then
        return false, encodeErr or "encode_failed"
    end

    local ok, err = writeRawFile(TMP_FILE_NAME, encodedEnvelope.raw)
    if not ok then
        return false, err or "tmp_write_failed"
    end

    local existingMain = readRawFile(PRIMARY_FILE_NAME)
    if opts.rotateBackup ~= false and type(existingMain) == "string" and existingMain ~= "" then
        local backupOk, backupErr = writeRawFile(BACKUP_FILE_NAME, existingMain)
        if not backupOk then
            removeRawFile(TMP_FILE_NAME)
            return false, backupErr or "backup_write_failed"
        end
    end

    ok, err = writeRawFile(PRIMARY_FILE_NAME, encodedEnvelope.raw)
    removeRawFile(TMP_FILE_NAME)
    if not ok then
        return false, err or "main_write_failed"
    end

    state.cacheEnvelope = encodedEnvelope
    state.cache = sanitizeProfile(encodedEnvelope.profile)
    state.cacheSource = opts.source or "save"
    return true, encodedEnvelope
end

local function queueRepairNotice()
    if state.repairNoticeShown or state.repairNoticePending then
        return
    end
    state.repairNoticePending = true
end

local function clearCache()
    state.cache = nil
    state.cacheEnvelope = nil
    state.cacheSource = nil
end

local function seedProfileFromVisibleState(seedScore, sourceLabel, liveMirrors)
    local cfg = (SETTINGS and (SETTINGS.RATING or SETTINGS.ELO)) or {}
    local mirrors = liveMirrors or fetchLiveMirrors()
    local hasStats = type(mirrors) == "table"
    local defaultRating = tonumber(cfg.DEFAULT_RATING) or 1200
    local defaultRd = tonumber(cfg.DEFAULT_RD) or 350
    local migratedRd = tonumber(cfg.MIGRATED_DEFAULT_RD) or 200

    local rating = hasStats and tonumber(mirrors.currentRating) or tonumber(seedScore) or defaultRating
    local games = hasStats and integerMirror(mirrors.onlineMatchesPlayed) or 0
    local seededFromLeaderboard = not hasStats and tonumber(seedScore) ~= nil
    local seededFromStats = hasStats and tonumber(mirrors.currentRating) ~= nil
    local rd = (seededFromLeaderboard or seededFromStats) and migratedRd or defaultRd

    local profile = glicko2.newProfile(rating, {
        rd = rd,
        games = games,
        seededFromLeaderboard = seededFromLeaderboard
    })
    local envelope = buildEnvelope(profile, {
        liveMirrors = mirrors,
        revision = 1
    })
    local ok, persisted = persistEnvelope(envelope, {
        rotateBackup = false,
        source = sourceLabel
    })
    if not ok then
        return profile, sourceLabel, nil
    end
    return sanitizeProfile(persisted.profile), sourceLabel, persisted
end

local function loadEnvelopeFromFile(fileName, opts)
    local content, readErr = readRawFile(fileName)
    if not content then
        return nil, nil, readErr or "missing"
    end

    if content:sub(1, #MAGIC) == MAGIC then
        local decoded, decodeErr = decodeV2Envelope(content)
        if not decoded then
            return nil, nil, decodeErr or "decode_failed"
        end
        local validated, validateErr = validateEnvelope(decoded, opts)
        if not validated then
            return nil, nil, validateErr or "validate_failed"
        end
        return validated, "v2"
    end

    local legacyEnvelope, legacyErr = decodeLegacyEnvelope(content)
    if not legacyEnvelope then
        return nil, nil, legacyErr or "legacy_decode_failed"
    end

    local profile, profileErr = glicko2.validateProfile(legacyEnvelope.profile, currentDay())
    if not profile then
        return nil, nil, profileErr or "legacy_profile_invalid"
    end
    legacyEnvelope.profile = profile
    return legacyEnvelope, "v1"
end

local function migrateLegacyEnvelope(legacyEnvelope, opts)
    opts = opts or {}
    local envelope = buildEnvelope(legacyEnvelope.profile, {
        liveMirrors = opts.liveMirrors,
        revision = 1
    })
    local ok, persisted = persistEnvelope(envelope, {
        rotateBackup = false,
        source = "migrated_v1"
    })
    if not ok then
        return nil, "migration_write_failed"
    end
    return sanitizeProfile(persisted.profile), "migrated_v1"
end

function ratingStore.getPath()
    return resolvePath(PRIMARY_FILE_NAME)
end

function ratingStore.getBackupPath()
    return resolvePath(BACKUP_FILE_NAME)
end

function ratingStore.loadRawEnvelope()
    local liveMirrors = fetchLiveMirrors()
    local envelope, formatKind, err = loadEnvelopeFromFile(PRIMARY_FILE_NAME, {
        ownerSteamId = currentOwnerSteamId(),
        appId = currentAppId(),
        liveMirrors = liveMirrors
    })
    if not envelope then
        return nil, err or "missing"
    end
    if formatKind == "v1" then
        local _, source = migrateLegacyEnvelope(envelope, { liveMirrors = liveMirrors })
        local migrated = state.cacheEnvelope
        return migrated, source or "migrated_v1"
    end
    state.cacheEnvelope = envelope
    state.cache = sanitizeProfile(envelope.profile)
    state.cacheSource = "file"
    return clone(envelope), "file"
end

function ratingStore.loadProfile()
    if state.cache then
        return sanitizeProfile(state.cache), state.cacheSource or "cache"
    end

    local liveMirrors = fetchLiveMirrors()
    local envelope, formatKind, loadErr = loadEnvelopeFromFile(PRIMARY_FILE_NAME, {
        ownerSteamId = currentOwnerSteamId(),
        appId = currentAppId(),
        liveMirrors = liveMirrors
    })

    if envelope then
        if formatKind == "v1" then
            return migrateLegacyEnvelope(envelope, { liveMirrors = liveMirrors })
        end
        state.cacheEnvelope = envelope
        state.cache = sanitizeProfile(envelope.profile)
        state.cacheSource = "file"
        return sanitizeProfile(state.cache), "file"
    end


    local backupEnvelope, backupFormat, backupErr = loadEnvelopeFromFile(BACKUP_FILE_NAME, {
        ownerSteamId = currentOwnerSteamId(),
        appId = currentAppId(),
        liveMirrors = liveMirrors
    })
    if backupEnvelope and backupFormat == "v2" then
        local restoreOk = persistEnvelope(backupEnvelope, {
            rotateBackup = false,
            source = "repaired_backup"
        })
        if restoreOk then
            queueRepairNotice()
            return sanitizeProfile(state.cache), "repaired_backup"
        end
    elseif backupEnvelope and backupFormat == "v1" then
        local migratedProfile, migratedSource = migrateLegacyEnvelope(backupEnvelope, { liveMirrors = liveMirrors })
        if migratedProfile then
            queueRepairNotice()
            return migratedProfile, migratedSource or "repaired_backup"
        end
    end

    local reseededProfile, source = seedProfileFromVisibleState(nil, "repaired_reseed", liveMirrors)
    queueRepairNotice()
    return reseededProfile, source or backupErr or loadErr or "repaired_reseed"
end

function ratingStore.saveProfile(profile)
    local envelope = buildEnvelope(profile)
    local ok, persistedOrErr = persistEnvelope(envelope, {
        source = "save"
    })
    if not ok then
        return false, persistedOrErr or "write_failed"
    end
    return true
end

function ratingStore.clear()
    clearCache()
    removeRawFile(TMP_FILE_NAME)
    local primaryOk = removeRawFile(PRIMARY_FILE_NAME)
    local backupOk = removeRawFile(BACKUP_FILE_NAME)
    return primaryOk == true and backupOk == true
end

function ratingStore.ensureLocalProfile(seedScore)
    local profile, source = ratingStore.loadProfile()
    if profile then
        return profile, source or "existing"
    end

    local liveMirrors = fetchLiveMirrors()
    local seededProfile, seededSource = seedProfileFromVisibleState(seedScore, liveMirrors and "seeded_stats" or ((tonumber(seedScore) ~= nil) and "seeded_leaderboard" or "default"), liveMirrors)
    return seededProfile, seededSource
end

function ratingStore.consumeRepairNotice()
    if not state.repairNoticePending then
        return nil
    end
    state.repairNoticePending = false
    state.repairNoticeShown = true
    return {
        title = REPAIR_NOTICE_TITLE,
        text = REPAIR_NOTICE_TEXT
    }
end

function ratingStore._buildMirrors(profile, liveMirrors, fallbackMirrors)
    return normalizeMirrors(liveMirrors, profile, fallbackMirrors)
end

function ratingStore._encodeV2Envelope(envelope)
    local encoded, err = encodeV2Envelope(envelope)
    if not encoded then
        return nil, err
    end
    return encoded.raw, encoded
end

function ratingStore._decodeV2Envelope(content)
    return decodeV2Envelope(content)
end

function ratingStore._decodeLegacyEnvelope(content)
    return decodeLegacyEnvelope(content)
end

function ratingStore._validateEnvelope(envelope, opts)
    return validateEnvelope(envelope, opts)
end

function ratingStore._resetTestState()
    clearCache()
    state.repairNoticePending = false
    state.repairNoticeShown = false
end

return ratingStore
