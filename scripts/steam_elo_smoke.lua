package.path = package.path .. ";./?.lua"

SETTINGS = SETTINGS or {}
SETTINGS.RATING = SETTINGS.RATING or {
    LEADERBOARD_NAME = "global_glicko2_v1",
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
    UPDATE_ON_DRAW = true,
    UPDATE_ON_TIMEOUT_FORFEIT = true,
    UPDATE_ON_DESYNC_ABORT = false,
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

local function assertApprox(actual, expected, tolerance, message)
    if math.abs(actual - expected) > tolerance then
        error((message or "assertApprox failed") .. string.format(" (actual=%s expected=%s tolerance=%s)", tostring(actual), tostring(expected), tostring(tolerance)), 2)
    end
end

runTest("glicko_default_profile_uses_expected_defaults", function()
    local profile = glicko2.newProfile()
    assertTrue(profile.rating == 1200, "default rating should remain 1200")
    assertTrue(profile.rd == 350, "default RD should be 350")
    assertApprox(profile.vol, 0.06, 0.000001, "default volatility mismatch")
end)

runTest("glicko_win_increases_rating_and_reduces_rd", function()
    local day = 21000
    local localProfile = glicko2.prepareProfileForMatch(glicko2.newProfile(1200, {rd = 200, games = 10, lastPeriodDay = day}), day)
    local opponentProfile = glicko2.prepareProfileForMatch(glicko2.newProfile(1200, {rd = 200, games = 10, lastPeriodDay = day}), day)
    local updated, summary = glicko2.computeNextProfile(localProfile, opponentProfile, 1.0, {
        ranked = true,
        currentDay = day,
        opponentId = "peerA"
    })
    assertTrue(updated.rating > localProfile.rating, "winner should gain rating")
    assertTrue(updated.rd < localProfile.rd, "rated match should reduce RD")
    assertTrue(summary.localDelta > 0, "summary delta should be positive")
end)

runTest("glicko_draw_against_stronger_player_increases_rating", function()
    local day = 21000
    local lower = glicko2.prepareProfileForMatch(glicko2.newProfile(1100, {rd = 120, games = 20, lastPeriodDay = day}), day)
    local higher = glicko2.prepareProfileForMatch(glicko2.newProfile(1350, {rd = 120, games = 20, lastPeriodDay = day}), day)
    local updated, summary = glicko2.computeNextProfile(lower, higher, 0.5, {
        ranked = true,
        currentDay = day,
        opponentId = "peerB"
    })
    assertTrue(updated.rating > lower.rating, "lower-rated player should gain on draw")
    assertTrue(summary.localDelta > 0, "draw delta should be positive for lower-rated player")
end)

runTest("glicko_inactivity_increases_rd", function()
    local profile = glicko2.prepareProfileForMatch(glicko2.newProfile(1200, {
        rd = 90,
        lastPeriodDay = 100
    }), 110)
    assertTrue(profile.rd > 90, "inactivity should increase RD")
end)

runTest("rematch_guard_blocks_third_same_opponent_within_window", function()
    local day = 30000
    local first = glicko2.newProfile(1200, {
        lastOpponentHash = glicko2.hashOpponentId("peerA"),
        sameOpponentStreak = 2,
        lastRankedDay = day
    })
    local guard = glicko2.evaluateRematchGuard(first, "peerA", day)
    assertTrue(guard.ranked == false, "third same-opponent match should be unranked")
    assertTrue(guard.reason == "repeat_opponent_guard", "guard reason mismatch")
end)

runTest("rematch_guard_resets_after_other_opponent", function()
    local day = 30000
    local profile = glicko2.newProfile(1200, {
        lastOpponentHash = glicko2.hashOpponentId("peerA"),
        sameOpponentStreak = 2,
        lastRankedDay = day
    })
    local guard = glicko2.evaluateRematchGuard(profile, "peerB", day)
    assertTrue(guard.ranked == true, "different opponent should reset guard")
    assertTrue(guard.nextStreak == 1, "different opponent should restart streak at 1")
end)

runTest("match_context_marks_unranked_when_one_side_guard_trips", function()
    local day = 30000
    local host = glicko2.newProfile(1200, {
        lastOpponentHash = glicko2.hashOpponentId("guest"),
        sameOpponentStreak = 2,
        lastRankedDay = day
    })
    local guest = glicko2.newProfile(1200, {lastRankedDay = day})
    local context = glicko2.buildMatchContext(host, guest, "host", "guest", day)
    assertTrue(context.ranked == false, "host guard should make match unranked")
end)

runTest("unranked_update_preserves_rating_but_advances_guard", function()
    local day = 30000
    local profile = glicko2.newProfile(1200, {
        lastOpponentHash = glicko2.hashOpponentId("peerA"),
        sameOpponentStreak = 2,
        lastRankedDay = day
    })
    local opponent = glicko2.newProfile(1200)
    local updated, summary = glicko2.computeNextProfile(profile, opponent, 1.0, {
        ranked = false,
        currentDay = day,
        opponentId = "peerA"
    })
    assertTrue(updated.rating == profile.rating, "unranked match should not change rating")
    assertTrue(updated.sameOpponentStreak == 3, "guard streak should still advance")
    assertTrue(summary.ranked == false, "summary should mark match unranked")
end)

runTest("count_game_false_preserves_games", function()
    local day = 30000
    local profile = glicko2.newProfile(1200, {
        games = 12,
        lastPeriodDay = day,
        lastRankedDay = day
    })
    local opponent = glicko2.newProfile(1200, {
        games = 9,
        lastPeriodDay = day,
        lastRankedDay = day
    })
    local updated = select(1, glicko2.computeNextProfile(profile, opponent, 1.0, {
        ranked = true,
        currentDay = day,
        opponentId = "peerA",
        countGame = false
    }))
    assertTrue(updated.games == profile.games, "countGame=false should preserve games")
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
    end
end

print("# Steam Rating Smoke Report")
print("")
print("- Passed: " .. tostring(passed))
print("- Failed: " .. tostring(#results - passed))
print("")
for _, result in ipairs(results) do
    local status = result.ok and "PASS" or "FAIL"
    print(string.format("- `%s` %s", status, result.name))
    if not result.ok then
        print("  - Error: " .. tostring(result.err))
    end
end

os.exit(((#results - passed) == 0) and 0 or 1)
