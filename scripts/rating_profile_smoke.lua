package.path = package.path .. ";./?.lua"

SETTINGS = SETTINGS or {}
SETTINGS.STEAM = SETTINGS.STEAM or { APP_ID = "1573941" }
SETTINGS.RATING = SETTINGS.RATING or {
    DEFAULT_RATING = 1200,
    DEFAULT_RD = 350,
    MIGRATED_DEFAULT_RD = 200,
    DEFAULT_VOLATILITY = 0.06,
    TAU = 0.5,
    CONVERGENCE_EPSILON = 0.000001,
    MIN_RATING = 100,
    MAX_RATING = 5000,
    MIN_RD = 40,
    MAX_RD = 350,
    REMATCH_WINDOW_DAYS = 1,
    REMATCH_MAX_RANKED = 2,
    PROFILE_FILE = "OnlineRatingProfile.dat"
}
SETTINGS.ELO = SETTINGS.RATING

local glicko2 = require("glicko2_rating")

local results = {}

local function runTest(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = {name = name, ok = ok, err = err}
end

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "assertEqual failed") .. string.format(" (actual=%s expected=%s)", tostring(actual), tostring(expected)), 2)
    end
end

local function makeFs(initialFiles)
    local files = {}
    local writes = {}
    for key, value in pairs(initialFiles or {}) do
        files[key] = value
    end

    local fs = {}
    function fs.read(name)
        return files[name]
    end
    function fs.write(name, content)
        files[name] = content
        writes[#writes + 1] = "write:" .. tostring(name)
        return true
    end
    function fs.remove(name)
        files[name] = nil
        writes[#writes + 1] = "remove:" .. tostring(name)
        return true
    end
    function fs.getSaveDirectory()
        return "/tmp/MeowOverMooRatingSmoke"
    end

    return files, writes, fs
end

local function resetModules()
    package.loaded["online_rating_store"] = nil
    package.loaded["steam_runtime"] = nil
    package.loaded["achievement_defs"] = nil
end

local function newSteamRuntimeStub(opts)
    opts = opts or {}
    local stats = {
        STAT_CURRENT_RATING = opts.currentRating or 1200,
        STAT_HIGHEST_RATING = opts.highestRating or (opts.currentRating or 1200),
        STAT_ONLINE_MATCHES_PLAYED = opts.onlineMatchesPlayed or 0,
        STAT_ONLINE_MATCHES_WON = opts.onlineMatchesWon or 0
    }
    local userId = tostring(opts.userId or "76561198000000001")
    return {
        _stats = stats,
        getLocalUserId = function()
            return userId
        end,
        getStatInt = function(id)
            return stats[id]
        end,
        setStatInt = function(id, value)
            stats[id] = math.floor(tonumber(value) or 0)
            return true
        end,
        incrementStatInt = function(id, delta)
            stats[id] = math.floor(tonumber(stats[id] or 0) + tonumber(delta or 0))
            return stats[id]
        end,
        storeUserStats = function()
            return true
        end,
        computeRatingProfileSignature = function()
            return nil, "native_signature_unavailable"
        end
    }
end

local function loadStore(config)
    resetModules()
    local files, writes, fs = makeFs(config.files)
    love = {
        filesystem = fs,
        timer = {
            getTime = function()
                return 1700000000
            end
        }
    }
    package.preload["steam_runtime"] = function()
        return newSteamRuntimeStub(config)
    end
    local store = require("online_rating_store")
    store._resetTestState()
    return store, files, writes, require("steam_runtime")
end

local function makeLegacyProfileText(profile)
    return string.format([[return {
    version = 1,
    profile = {
        rating = %s,
        rd = %s,
        vol = %s,
        games = %s,
        lastPeriodDay = %s,
        lastOpponentHash = %s,
        sameOpponentStreak = %s,
        lastRankedDay = %s,
        seededFromLeaderboard = false
    }
}
]], tostring(profile.rating), tostring(profile.rd), tostring(profile.vol), tostring(profile.games), tostring(profile.lastPeriodDay), tostring(profile.lastOpponentHash or 0), tostring(profile.sameOpponentStreak or 0), tostring(profile.lastRankedDay))
end

runTest("valid_v1_profile_migrates_to_signed_v2", function()
    local legacyText = makeLegacyProfileText({
        rating = 1337, rd = 150, vol = 0.06, games = 7, lastPeriodDay = 19000, lastRankedDay = 19000
    })
    local store, files = loadStore({
        files = { ["OnlineRatingProfile.dat"] = legacyText },
        currentRating = 1337,
        highestRating = 1337,
        onlineMatchesPlayed = 7,
        onlineMatchesWon = 3
    })

    local profile, source = store.loadProfile()
    assertEqual(source, "migrated_v1", "legacy profile should migrate")
    assertEqual(math.floor(profile.rating + 0.5), 1337, "migrated rating mismatch")
    assertTrue(type(files["OnlineRatingProfile.dat"]) == "string" and files["OnlineRatingProfile.dat"]:sub(1, 6) == "MOMRP2", "migrated file should be v2 encoded")
end)

runTest("profile_signed_for_one_steamid_fails_on_another", function()
    local store, files = loadStore({
        userId = "76561198000000001",
        currentRating = 1200,
        highestRating = 1200,
        onlineMatchesPlayed = 5,
        onlineMatchesWon = 2
    })
    local ok = store.saveProfile(glicko2.newProfile(1200, { games = 5 }))
    assertTrue(ok == true, "initial save should succeed")

    store, files = loadStore({
        files = files,
        userId = "76561198000000002",
        currentRating = 1200,
        highestRating = 1200,
        onlineMatchesPlayed = 0,
        onlineMatchesWon = 0
    })
    local profile, source = store.loadProfile()
    assertTrue(source == "repaired_reseed" or source == "repaired_backup", "owner mismatch should repair profile")
    assertEqual(math.floor(profile.rating + 0.5), 1200, "reseeded rating should come from visible state")
    assertTrue(store.consumeRepairNotice() ~= nil, "repair notice should be staged")
end)

runTest("stat_mismatch_invalidates_main_profile", function()
    local store, files = loadStore({
        currentRating = 1450,
        highestRating = 1450,
        onlineMatchesPlayed = 9,
        onlineMatchesWon = 4
    })
    assertTrue(store.saveProfile(glicko2.newProfile(1450, { games = 9 })) == true, "save should succeed")

    store, files = loadStore({
        files = files,
        currentRating = 1200,
        highestRating = 1200,
        onlineMatchesPlayed = 0,
        onlineMatchesWon = 0
    })
    local profile, source = store.loadProfile()
    assertTrue(source == "repaired_reseed", "stat mismatch should reseed when backup also mismatches")
    assertEqual(math.floor(profile.rating + 0.5), 1200, "reseeded rating should use live stat value")
end)

runTest("corrupted_main_profile_restores_from_backup", function()
    local store, files = loadStore({
        currentRating = 1325,
        highestRating = 1400,
        onlineMatchesPlayed = 6,
        onlineMatchesWon = 3
    })
    assertTrue(store.saveProfile(glicko2.newProfile(1325, { games = 6 })) == true, "save should succeed")
    files["OnlineRatingProfile.bak"] = files["OnlineRatingProfile.dat"]
    files["OnlineRatingProfile.dat"] = "broken-data"

    store, files = loadStore({
        files = files,
        currentRating = 1325,
        highestRating = 1400,
        onlineMatchesPlayed = 6,
        onlineMatchesWon = 3
    })
    local profile, source = store.loadProfile()
    assertEqual(source, "repaired_backup", "backup should restore when main is corrupt")
    assertEqual(math.floor(profile.rating + 0.5), 1325, "backup should preserve rating")
end)

runTest("corrupted_main_and_backup_reseed_safely", function()
    local store = loadStore({
        files = {
            ["OnlineRatingProfile.dat"] = "bad-main",
            ["OnlineRatingProfile.bak"] = "bad-backup"
        },
        currentRating = 1510,
        highestRating = 1510,
        onlineMatchesPlayed = 11,
        onlineMatchesWon = 5
    })
    local profile, source = store.loadProfile()
    assertEqual(source, "repaired_reseed", "double corruption should reseed")
    assertEqual(math.floor(profile.rating + 0.5), 1510, "reseed should use live rating")
    assertEqual(profile.games, 11, "reseed should use live matches played")
end)

runTest("impossible_profile_values_are_rejected", function()
    local store = loadStore({
        currentRating = 1200,
        highestRating = 1200,
        onlineMatchesPlayed = 1,
        onlineMatchesWon = 0
    })
    local envelope = {
        version = 2,
        ownerSteamId = "76561198000000001",
        appId = "1573941",
        revision = 1,
        savedAt = 1700000000,
        profile = { rating = 1200, rd = 999, vol = 9, games = 1, lastPeriodDay = 30000, lastOpponentHash = 0, sameOpponentStreak = 0, lastRankedDay = 30000 },
        mirrors = { currentRating = 1200, highestRating = 1200, onlineMatchesPlayed = 1, onlineMatchesWon = 0 },
        signature = "L1:deadbeefdeadbeef"
    }
    local ok = store._validateEnvelope(envelope, {
        ownerSteamId = "76561198000000001",
        appId = "1573941",
        liveMirrors = { currentRating = 1200, highestRating = 1200, onlineMatchesPlayed = 1, onlineMatchesWon = 0 }
    })
    assertTrue(ok == nil, "invalid profile should be rejected")
end)

runTest("save_path_writes_tmp_backup_main_in_order", function()
    local store, _, writes = loadStore({
        currentRating = 1250,
        highestRating = 1250,
        onlineMatchesPlayed = 2,
        onlineMatchesWon = 1
    })
    assertTrue(store.saveProfile(glicko2.newProfile(1250, { games = 2 })) == true, "initial save should succeed")
    while #writes > 0 do table.remove(writes) end
    assertTrue(store.saveProfile(glicko2.newProfile(1260, { games = 2 })) == true, "second save should succeed")
    local joined = table.concat(writes, ",")
    assertTrue(joined:find("write:OnlineRatingProfile.dat.tmp", 1, true) ~= nil, "tmp write missing")
    assertTrue(joined:find("write:OnlineRatingProfile.bak", 1, true) ~= nil, "backup write missing")
    assertTrue(joined:find("write:OnlineRatingProfile.dat", 1, true) ~= nil, "main write missing")
    assertTrue(joined:find("remove:OnlineRatingProfile.dat.tmp", 1, true) ~= nil, "tmp cleanup missing")
end)

runTest("repair_notification_is_staged_once", function()
    local store = loadStore({
        files = { ["OnlineRatingProfile.dat"] = "bad-main", ["OnlineRatingProfile.bak"] = "bad-backup" },
        currentRating = 1200,
        highestRating = 1200,
        onlineMatchesPlayed = 0,
        onlineMatchesWon = 0
    })
    store.loadProfile()
    assertTrue(store.consumeRepairNotice() ~= nil, "repair notice should be available once")
    assertTrue(store.consumeRepairNotice() == nil, "repair notice should not repeat")
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
        print("[PASS] " .. result.name)
    else
        print("[FAIL] " .. result.name .. " -> " .. tostring(result.err))
    end
end

print(string.format("rating_profile_smoke: %d/%d passed", passed, #results))
os.exit(((#results - passed) == 0) and 0 or 1)
