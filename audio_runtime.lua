local audioRuntime = {}

local state = {
    initialized = false,
    lastPlaybackAt = nil,
    lastPlaybackPath = nil,
    lastPlaybackCategory = nil,
    focus = true,
    visible = true,
    lastFocusChangeAt = nil,
    lastVisibilityChangeAt = nil,
    lastResumeAt = nil,
    lastResumeReason = nil,
    lastResumeSucceeded = nil,
    lastResumeActiveSourceCount = nil,
    activeSourceCount = nil,
    lastActiveSourceCountAt = nil,
    lastActiveSourceCountReason = nil,
    remotePlayWindowStartedAt = nil,
    remotePlayWindowReason = nil,
    remotePlayPlaybackSeen = false,
    remotePlayWarningShown = false,
    remotePlaySessionStartedAt = nil,
    remotePlaySessionReason = nil,
    remotePlaySessionFirstPlaybackAt = nil,
    remotePlaySessionFirstPlaybackPath = nil,
    remotePlayMatchStartedAt = nil,
    remotePlayMatchReason = nil,
    remotePlayMatchFirstPlaybackAt = nil,
    remotePlayMatchFirstPlaybackPath = nil,
}

local function nowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

local function audioConfig()
    local audio = ((SETTINGS or {}).AUDIO or {})
    return {
        sfxEnabled = audio.SFX ~= false,
        sfxVolume = tonumber(audio.SFX_VOLUME) or 0,
        musicEnabled = audio.MUSIC ~= false,
        musicVolume = tonumber(audio.MUSIC_VOLUME) or 0,
    }
end

local function shouldLogAudioDebug()
    return (((SETTINGS or {}).STEAM or {}).DEBUG_LOGS == true) or (((DEBUG or {}).AUDIO) == true)
end

local function logAudioDebug(message)
    if shouldLogAudioDebug() then
        print(message)
    end
end

local function hasRemotePlayDiagnosticsWindow()
    return state.remotePlayWindowStartedAt ~= nil or state.remotePlaySessionStartedAt ~= nil or state.remotePlayMatchStartedAt ~= nil
end

local function logLifecycleEvent(kind, value)
    if not hasRemotePlayDiagnosticsWindow() then
        return
    end
    logAudioDebug(string.format("[RemotePlayAudio] %s=%s", tostring(kind), tostring(value)))
end

local function isMatchReason(reason)
    return tostring(reason or ""):find("match", 1, true) ~= nil
end

local function getActiveSourceCountRaw()
    if love and love.audio and type(love.audio.getActiveSourceCount) == "function" then
        local ok, count = pcall(love.audio.getActiveSourceCount)
        if ok and type(count) == "number" then
            return math.max(0, math.floor(count))
        end
    end
    return nil
end

local function sampleActiveSourceCount(reason)
    local count = getActiveSourceCountRaw()
    state.activeSourceCount = count
    state.lastActiveSourceCountAt = nowSeconds()
    state.lastActiveSourceCountReason = tostring(reason or "sample")
    return count
end

function audioRuntime.init()
    state.initialized = true
    sampleActiveSourceCount("init")
end

function audioRuntime.onFocusChanged(focused)
    local normalized = focused ~= false
    if state.focus ~= normalized then
        state.lastFocusChangeAt = nowSeconds()
        state.focus = normalized
        logLifecycleEvent("focus", normalized)
        sampleActiveSourceCount(normalized and "focus_regained" or "focus_lost")
    end
    return normalized
end

function audioRuntime.onVisibilityChanged(visible)
    local normalized = visible ~= false
    if state.visible ~= normalized then
        state.lastVisibilityChangeAt = nowSeconds()
        state.visible = normalized
        logLifecycleEvent("visible", normalized)
        sampleActiveSourceCount(normalized and "visibility_regained" or "visibility_lost")
    end
    return normalized
end

function audioRuntime.resumeAudioOutput(reason)
    state.lastResumeAt = nowSeconds()
    state.lastResumeReason = tostring(reason or "resume")
    logLifecycleEvent("resume", state.lastResumeReason)

    local resumed = false
    if love and love.audio and type(love.audio.resume) == "function" then
        resumed = pcall(love.audio.resume) == true
    end

    state.lastResumeSucceeded = resumed
    state.lastResumeActiveSourceCount = sampleActiveSourceCount("resume:" .. state.lastResumeReason)
    return resumed
end

function audioRuntime.notePlayback(path, opts)
    state.lastPlaybackAt = nowSeconds()
    state.lastPlaybackPath = tostring(path or "")
    state.lastPlaybackCategory = tostring((opts and opts.category) or "sfx")
    sampleActiveSourceCount("playback:" .. state.lastPlaybackCategory)

    if state.remotePlayWindowStartedAt then
        state.remotePlayPlaybackSeen = true
    end
    if state.remotePlaySessionStartedAt and not state.remotePlaySessionFirstPlaybackAt then
        state.remotePlaySessionFirstPlaybackAt = state.lastPlaybackAt
        state.remotePlaySessionFirstPlaybackPath = state.lastPlaybackPath
        logAudioDebug(string.format(
            "[RemotePlayAudio] first_session_playback elapsed=%.2f path=%s activeSources=%s",
            math.max(0, state.remotePlaySessionFirstPlaybackAt - state.remotePlaySessionStartedAt),
            state.remotePlaySessionFirstPlaybackPath,
            tostring(state.activeSourceCount)
        ))
    end
    if state.remotePlayMatchStartedAt and not state.remotePlayMatchFirstPlaybackAt then
        state.remotePlayMatchFirstPlaybackAt = state.lastPlaybackAt
        state.remotePlayMatchFirstPlaybackPath = state.lastPlaybackPath
        logAudioDebug(string.format(
            "[RemotePlayAudio] first_match_playback elapsed=%.2f path=%s activeSources=%s",
            math.max(0, state.remotePlayMatchFirstPlaybackAt - state.remotePlayMatchStartedAt),
            state.remotePlayMatchFirstPlaybackPath,
            tostring(state.activeSourceCount)
        ))
    end
end

function audioRuntime.beginRemotePlaySession(reason)
    state.remotePlayWarningShown = false
    state.remotePlaySessionStartedAt = nowSeconds()
    state.remotePlaySessionReason = tostring(reason or "remote_play_session")
    state.remotePlaySessionFirstPlaybackAt = nil
    state.remotePlaySessionFirstPlaybackPath = nil
    state.remotePlayMatchStartedAt = nil
    state.remotePlayMatchReason = nil
    state.remotePlayMatchFirstPlaybackAt = nil
    state.remotePlayMatchFirstPlaybackPath = nil
    audioRuntime.resetRemotePlayWindow(reason or "remote_play_session")
    sampleActiveSourceCount("remote_play_session_start")
end

function audioRuntime.resetRemotePlayWindow(reason)
    state.remotePlayWindowStartedAt = nowSeconds()
    state.remotePlayWindowReason = tostring(reason or "remote_play")
    state.remotePlayPlaybackSeen = false
    if isMatchReason(reason) then
        state.remotePlayMatchStartedAt = state.remotePlayWindowStartedAt
        state.remotePlayMatchReason = state.remotePlayWindowReason
        state.remotePlayMatchFirstPlaybackAt = nil
        state.remotePlayMatchFirstPlaybackPath = nil
    end

    local cfg = audioConfig()
    sampleActiveSourceCount("window_reset:" .. state.remotePlayWindowReason)
    logAudioDebug(string.format(
        "[RemotePlayAudio] window_reset reason=%s sfx=%s sfxVol=%.2f music=%s musicVol=%.2f activeSources=%s",
        state.remotePlayWindowReason,
        tostring(cfg.sfxEnabled),
        cfg.sfxVolume,
        tostring(cfg.musicEnabled),
        cfg.musicVolume,
        tostring(state.activeSourceCount)
    ))
end

function audioRuntime.hasAudibleOutputEnabled()
    local cfg = audioConfig()
    return (cfg.sfxEnabled and cfg.sfxVolume > 0) or (cfg.musicEnabled and cfg.musicVolume > 0)
end

function audioRuntime.consumeRemotePlayMutedWarning()
    if audioRuntime.hasAudibleOutputEnabled() then
        return false
    end
    if state.remotePlayWarningShown then
        return false
    end
    state.remotePlayWarningShown = true
    return true
end

function audioRuntime.logRemotePlayWindowSummary(reason)
    if not state.remotePlayWindowStartedAt then
        return
    end
    sampleActiveSourceCount("summary:" .. tostring(reason or state.remotePlayWindowReason or "remote_play"))
    local elapsed = math.max(0, nowSeconds() - state.remotePlayWindowStartedAt)
    logAudioDebug(string.format(
        "[RemotePlayAudio] window_summary reason=%s elapsed=%.2f playbackSeen=%s lastPath=%s audible=%s activeSources=%s focus=%s visible=%s sessionFirst=%s matchFirst=%s lastResumeOk=%s lastResumeSources=%s",
        tostring(reason or state.remotePlayWindowReason or "remote_play"),
        elapsed,
        tostring(state.remotePlayPlaybackSeen),
        tostring(state.lastPlaybackPath or ""),
        tostring(audioRuntime.hasAudibleOutputEnabled()),
        tostring(state.activeSourceCount),
        tostring(state.focus),
        tostring(state.visible),
        tostring(state.remotePlaySessionFirstPlaybackPath or ""),
        tostring(state.remotePlayMatchFirstPlaybackPath or ""),
        tostring(state.lastResumeSucceeded),
        tostring(state.lastResumeActiveSourceCount)
    ))
end

function audioRuntime.getDiagnostics()
    local cfg = audioConfig()
    return {
        initialized = state.initialized == true,
        focused = state.focus == true,
        visible = state.visible == true,
        lastFocusChangeAt = state.lastFocusChangeAt,
        lastVisibilityChangeAt = state.lastVisibilityChangeAt,
        lastResumeAt = state.lastResumeAt,
        lastResumeReason = state.lastResumeReason,
        lastResumeSucceeded = state.lastResumeSucceeded,
        lastResumeActiveSourceCount = state.lastResumeActiveSourceCount,
        activeSourceCount = state.activeSourceCount,
        lastActiveSourceCountAt = state.lastActiveSourceCountAt,
        lastActiveSourceCountReason = state.lastActiveSourceCountReason,
        lastPlaybackAt = state.lastPlaybackAt,
        lastPlaybackPath = state.lastPlaybackPath,
        lastPlaybackCategory = state.lastPlaybackCategory,
        remotePlayWindowStartedAt = state.remotePlayWindowStartedAt,
        remotePlayWindowReason = state.remotePlayWindowReason,
        remotePlayPlaybackSeen = state.remotePlayPlaybackSeen == true,
        remotePlaySessionStartedAt = state.remotePlaySessionStartedAt,
        remotePlaySessionReason = state.remotePlaySessionReason,
        remotePlaySessionFirstPlaybackAt = state.remotePlaySessionFirstPlaybackAt,
        remotePlaySessionFirstPlaybackPath = state.remotePlaySessionFirstPlaybackPath,
        remotePlayMatchStartedAt = state.remotePlayMatchStartedAt,
        remotePlayMatchReason = state.remotePlayMatchReason,
        remotePlayMatchFirstPlaybackAt = state.remotePlayMatchFirstPlaybackAt,
        remotePlayMatchFirstPlaybackPath = state.remotePlayMatchFirstPlaybackPath,
        audibleOutputEnabled = audioRuntime.hasAudibleOutputEnabled(),
        sfxEnabled = cfg.sfxEnabled,
        sfxVolume = cfg.sfxVolume,
        musicEnabled = cfg.musicEnabled,
        musicVolume = cfg.musicVolume,
    }
end

return audioRuntime
