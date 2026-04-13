local glicko2 = {}

local SCALE = 173.7178
local PI_SQUARED = math.pi * math.pi

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, inner in pairs(value) do
        copy[key] = deepCopy(inner)
    end
    return copy
end

local function getConfig()
    local source = (SETTINGS and (SETTINGS.RATING or SETTINGS.ELO)) or {}
    return {
        ratingCenter = tonumber(source.DEFAULT_RATING) or 1200,
        defaultRating = tonumber(source.DEFAULT_RATING) or 1200,
        defaultRd = tonumber(source.DEFAULT_RD) or 350,
        migratedDefaultRd = tonumber(source.MIGRATED_DEFAULT_RD) or 200,
        defaultVolatility = tonumber(source.DEFAULT_VOLATILITY) or 0.06,
        tau = tonumber(source.TAU) or 0.5,
        epsilon = tonumber(source.CONVERGENCE_EPSILON) or 0.000001,
        minRating = tonumber(source.MIN_RATING) or 100,
        maxRating = tonumber(source.MAX_RATING) or 5000,
        minRd = tonumber(source.MIN_RD) or 40,
        maxRd = tonumber(source.MAX_RD) or 350,
        rematchWindowDays = tonumber(source.REMATCH_WINDOW_DAYS) or 1,
        rematchMaxRanked = tonumber(source.REMATCH_MAX_RANKED) or 2,
        profileFile = tostring(source.PROFILE_FILE or "OnlineRatingProfile.dat")
    }
end

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function round(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

local function nowSeconds(nowValue)
    if tonumber(nowValue) then
        return tonumber(nowValue)
    end
    if love and love.timer and type(love.timer.getTime) == "function" then
        return love.timer.getTime()
    end
    if os and type(os.time) == "function" then
        return os.time()
    end
    return 0
end

function glicko2.currentDay(nowValue)
    return math.floor(nowSeconds(nowValue) / 86400)
end

function glicko2.hashOpponentId(value)
    local text = tostring(value or "")
    if text == "" then
        return 0
    end

    local hash = 0
    for i = 1, #text do
        hash = (hash * 131 + string.byte(text, i)) % 2147483647
    end
    return math.floor(hash)
end

local function sanitizeProfile(profile, currentDay)
    local cfg = getConfig()
    local day = tonumber(currentDay) or glicko2.currentDay()
    local normalized = type(profile) == "table" and deepCopy(profile) or {}

    normalized.version = 1
    normalized.rating = clamp(tonumber(normalized.rating) or cfg.defaultRating, cfg.minRating, cfg.maxRating)
    normalized.rd = clamp(tonumber(normalized.rd) or cfg.defaultRd, cfg.minRd, cfg.maxRd)
    normalized.vol = clamp(tonumber(normalized.vol) or cfg.defaultVolatility, 0.01, 1.2)
    normalized.games = math.max(0, math.floor(tonumber(normalized.games) or 0))
    normalized.lastPeriodDay = math.max(0, math.floor(tonumber(normalized.lastPeriodDay) or day))
    normalized.lastOpponentHash = math.max(0, math.floor(tonumber(normalized.lastOpponentHash) or 0))
    normalized.sameOpponentStreak = math.max(0, math.floor(tonumber(normalized.sameOpponentStreak) or 0))
    normalized.lastRankedDay = math.max(0, math.floor(tonumber(normalized.lastRankedDay) or 0))
    normalized.seededFromLeaderboard = normalized.seededFromLeaderboard == true
    return normalized
end

glicko2.sanitizeProfile = sanitizeProfile

function glicko2.validateProfile(profile, currentDay)
    local cfg = getConfig()
    local day = tonumber(currentDay) or glicko2.currentDay()
    if type(profile) ~= "table" then
        return nil, "profile_not_table"
    end

    local rating = tonumber(profile.rating)
    if rating == nil or rating ~= rating or rating < cfg.minRating or rating > cfg.maxRating then
        return nil, "profile_rating_invalid"
    end

    local rd = tonumber(profile.rd)
    if rd == nil or rd ~= rd or rd < cfg.minRd or rd > cfg.maxRd then
        return nil, "profile_rd_invalid"
    end

    local vol = tonumber(profile.vol)
    if vol == nil or vol ~= vol or vol < 0.01 or vol > 1.2 then
        return nil, "profile_vol_invalid"
    end

    local games = tonumber(profile.games)
    if games == nil or games < 0 then
        return nil, "profile_games_invalid"
    end

    local lastPeriodDay = tonumber(profile.lastPeriodDay)
    if lastPeriodDay == nil or lastPeriodDay < 0 or lastPeriodDay > (day + 366) then
        return nil, "profile_last_period_invalid"
    end

    local lastOpponentHash = tonumber(profile.lastOpponentHash)
    if lastOpponentHash == nil or lastOpponentHash < 0 then
        return nil, "profile_last_opponent_invalid"
    end

    local sameOpponentStreak = tonumber(profile.sameOpponentStreak)
    if sameOpponentStreak == nil or sameOpponentStreak < 0 or sameOpponentStreak > 9999 then
        return nil, "profile_same_opponent_streak_invalid"
    end

    local lastRankedDay = tonumber(profile.lastRankedDay)
    if lastRankedDay == nil or lastRankedDay < 0 or lastRankedDay > lastPeriodDay then
        return nil, "profile_last_ranked_invalid"
    end

    return sanitizeProfile(profile, day)
end


function glicko2.newProfile(seedRating, opts)
    opts = opts or {}
    local cfg = getConfig()
    local day = glicko2.currentDay(opts.now)
    return sanitizeProfile({
        rating = tonumber(seedRating) or cfg.defaultRating,
        rd = tonumber(opts.rd) or cfg.defaultRd,
        vol = tonumber(opts.vol) or cfg.defaultVolatility,
        games = math.max(0, math.floor(tonumber(opts.games) or 0)),
        lastPeriodDay = tonumber(opts.lastPeriodDay) or day,
        lastOpponentHash = tonumber(opts.lastOpponentHash) or 0,
        sameOpponentStreak = tonumber(opts.sameOpponentStreak) or 0,
        lastRankedDay = tonumber(opts.lastRankedDay) or 0,
        seededFromLeaderboard = opts.seededFromLeaderboard == true
    }, day)
end

function glicko2.prepareProfileForMatch(profile, currentDay)
    local cfg = getConfig()
    local day = tonumber(currentDay) or glicko2.currentDay()
    local prepared = sanitizeProfile(profile, day)

    if day > prepared.lastPeriodDay then
        local elapsed = day - prepared.lastPeriodDay
        local phi = prepared.rd / SCALE
        phi = math.sqrt(phi * phi + elapsed * prepared.vol * prepared.vol)
        prepared.rd = clamp(phi * SCALE, cfg.minRd, cfg.maxRd)
        prepared.lastPeriodDay = day
    end

    return prepared
end

local function volatilityFunction(x, delta, phi, variance, a, tau)
    local ex = math.exp(x)
    local numerator = ex * (delta * delta - phi * phi - variance - ex)
    local denominator = 2 * (phi * phi + variance + ex) * (phi * phi + variance + ex)
    return numerator / denominator - (x - a) / (tau * tau)
end

local function updateVolatility(phi, delta, variance, sigma, tau, epsilon)
    local a = math.log(sigma * sigma)
    local A = a
    local B

    if delta * delta > phi * phi + variance then
        B = math.log(delta * delta - phi * phi - variance)
    else
        local k = 1
        B = a - k * tau
        while volatilityFunction(B, delta, phi, variance, a, tau) < 0 and k < 128 do
            k = k + 1
            B = a - k * tau
        end
    end

    local fA = volatilityFunction(A, delta, phi, variance, a, tau)
    local fB = volatilityFunction(B, delta, phi, variance, a, tau)

    for _ = 1, 128 do
        if math.abs(B - A) <= epsilon then
            break
        end
        local denominator = (fB - fA)
        if denominator == 0 then
            break
        end
        local C = A + (A - B) * fA / denominator
        local fC = volatilityFunction(C, delta, phi, variance, a, tau)
        if fC * fB < 0 then
            A = B
            fA = fB
        else
            fA = fA / 2
        end
        B = C
        fB = fC
    end

    local sigmaPrime = math.exp(A / 2)
    if sigmaPrime ~= sigmaPrime or sigmaPrime <= 0 then
        return sigma
    end
    return sigmaPrime
end

local function g(phi)
    return 1 / math.sqrt(1 + 3 * phi * phi / PI_SQUARED)
end

local function expected(mu, muJ, phiJ)
    return 1 / (1 + math.exp(-g(phiJ) * (mu - muJ)))
end

function glicko2.evaluateRematchGuard(profile, opponentId, currentDay)
    local cfg = getConfig()
    local day = tonumber(currentDay) or glicko2.currentDay()
    local prepared = sanitizeProfile(profile, day)
    local opponentHash = glicko2.hashOpponentId(opponentId)

    local sameOpponent = opponentHash ~= 0 and prepared.lastOpponentHash == opponentHash
    local withinWindow = prepared.lastRankedDay > 0 and (day - prepared.lastRankedDay) < cfg.rematchWindowDays

    local nextStreak = 1
    if sameOpponent and withinWindow then
        nextStreak = prepared.sameOpponentStreak + 1
    end

    local ranked = nextStreak <= cfg.rematchMaxRanked
    local reason = ranked and "ranked" or "repeat_opponent_guard"

    return {
        ranked = ranked,
        reason = reason,
        opponentHash = opponentHash,
        nextStreak = nextStreak,
        withinWindow = withinWindow,
        sameOpponent = sameOpponent
    }
end

function glicko2.buildMatchContext(hostProfile, guestProfile, hostUserId, guestUserId, currentDay)
    local day = tonumber(currentDay) or glicko2.currentDay()
    local preparedHost = glicko2.prepareProfileForMatch(hostProfile, day)
    local preparedGuest = glicko2.prepareProfileForMatch(guestProfile, day)
    local hostGuard = glicko2.evaluateRematchGuard(preparedHost, guestUserId, day)
    local guestGuard = glicko2.evaluateRematchGuard(preparedGuest, hostUserId, day)
    local ranked = hostGuard.ranked and guestGuard.ranked
    local reason = "ranked"
    if not ranked then
        if hostGuard.reason == guestGuard.reason then
            reason = hostGuard.reason
        elseif hostGuard.ranked ~= true then
            reason = "host_" .. tostring(hostGuard.reason)
        else
            reason = "guest_" .. tostring(guestGuard.reason)
        end
    end

    return {
        algorithm = "glicko2",
        matchDay = day,
        ranked = ranked,
        reason = reason,
        host = preparedHost,
        guest = preparedGuest,
        hostGuard = {
            ranked = hostGuard.ranked,
            reason = hostGuard.reason,
            opponentHash = hostGuard.opponentHash,
            nextStreak = hostGuard.nextStreak
        },
        guestGuard = {
            ranked = guestGuard.ranked,
            reason = guestGuard.reason,
            opponentHash = guestGuard.opponentHash,
            nextStreak = guestGuard.nextStreak
        }
    }
end

function glicko2.resolveLocalAndOpponentProfiles(matchContext, role)
    if type(matchContext) ~= "table" then
        return nil, nil
    end
    if tostring(role or "host") == "guest" then
        return deepCopy(matchContext.guest), deepCopy(matchContext.host)
    end
    return deepCopy(matchContext.host), deepCopy(matchContext.guest)
end

function glicko2.computeNextProfile(localProfile, opponentProfile, score, opts)
    opts = opts or {}
    local cfg = getConfig()
    local day = tonumber(opts.currentDay) or glicko2.currentDay()
    local ranked = opts.ranked ~= false
    local countGame = opts.countGame ~= false
    local opponentHash = tonumber(opts.opponentHash) or glicko2.hashOpponentId(opts.opponentId)

    local localState = sanitizeProfile(localProfile, day)
    local opponentState = sanitizeProfile(opponentProfile, day)
    local guard = glicko2.evaluateRematchGuard(localState, opts.opponentId or opponentHash, day)
    if opponentHash ~= 0 then
        guard.opponentHash = opponentHash
    end

    local updated = deepCopy(localState)
    updated.lastOpponentHash = guard.opponentHash or 0
    updated.sameOpponentStreak = guard.nextStreak or 1

    if not ranked or score == nil then
        return sanitizeProfile(updated, day), {
            ranked = false,
            reason = opts.reason or guard.reason or "unranked",
            localOld = localState.rating,
            localNew = localState.rating,
            localDelta = 0,
            localRdOld = localState.rd,
            localRdNew = localState.rd,
            localVolOld = localState.vol,
            localVolNew = localState.vol,
            displayScore = round(localState.rating)
        }
    end

    local mu = (localState.rating - cfg.ratingCenter) / SCALE
    local phi = localState.rd / SCALE
    local muJ = (opponentState.rating - cfg.ratingCenter) / SCALE
    local phiJ = opponentState.rd / SCALE

    local gPhi = g(phiJ)
    local expectedScore = expected(mu, muJ, phiJ)
    local variance = 1 / (gPhi * gPhi * expectedScore * (1 - expectedScore))
    local delta = variance * gPhi * ((tonumber(score) or 0) - expectedScore)
    local sigmaPrime = updateVolatility(phi, delta, variance, localState.vol, cfg.tau, cfg.epsilon)
    local phiStar = math.sqrt(phi * phi + sigmaPrime * sigmaPrime)
    local phiPrime = 1 / math.sqrt((1 / (phiStar * phiStar)) + (1 / variance))
    local muPrime = mu + phiPrime * phiPrime * gPhi * ((tonumber(score) or 0) - expectedScore)

    updated.rating = clamp(cfg.ratingCenter + SCALE * muPrime, cfg.minRating, cfg.maxRating)
    updated.rd = clamp(phiPrime * SCALE, cfg.minRd, cfg.maxRd)
    updated.vol = clamp(sigmaPrime, 0.01, 1.2)
    if countGame then
        updated.games = localState.games + 1
    end
    updated.lastPeriodDay = day
    updated.lastRankedDay = day

    local localOld = round(localState.rating)
    local localNew = round(updated.rating)

    return sanitizeProfile(updated, day), {
        ranked = true,
        reason = opts.reason or "ranked",
        localOld = localOld,
        localNew = localNew,
        localDelta = localNew - localOld,
        localRdOld = round(localState.rd),
        localRdNew = round(updated.rd),
        localVolOld = localState.vol,
        localVolNew = updated.vol,
        displayScore = localNew
    }
end

return glicko2
