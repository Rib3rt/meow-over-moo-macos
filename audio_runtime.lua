local audioRuntime = {}

local MUSIC_SETTINGS_FILE = "AudioSettings.lua"

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
    music = {
        id = nil,
        path = nil,
        source = nil,
        currentVolume = 0,
        targetVolume = 0,
        ducked = false,
        duckReason = nil
    },
    musicPreferenceLoaded = false
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
        gameplayMusicMultiplier = tonumber(audio.GAMEPLAY_MUSIC_MULTIPLIER) or 0.65,
        musicDuckMultiplier = tonumber(audio.MUSIC_DUCK_MULTIPLIER) or 0.35,
        musicFadeInSec = tonumber(audio.MUSIC_FADE_IN_SEC) or 1.8,
        musicFadeSec = tonumber(audio.MUSIC_FADE_SEC) or 0.45,
    }
end

local function hasFilesystemRead()
    return love
        and love.filesystem
        and type(love.filesystem.read) == "function"
end

local function hasFilesystemWrite()
    return love
        and love.filesystem
        and type(love.filesystem.write) == "function"
end

local function parseSavedMusicPreference(content)
    local raw = tostring(content or "")
    local value = raw:match("MUSIC%s*=%s*(true)")
        or raw:match("MUSIC%s*=%s*(false)")
    if value == "true" then
        return true
    end
    if value == "false" then
        return false
    end
    return nil
end

local function ensureAudioSettings()
    SETTINGS = SETTINGS or {}
    SETTINGS.AUDIO = SETTINGS.AUDIO or {}
    return SETTINGS.AUDIO
end

local function loadMusicPreference()
    if state.musicPreferenceLoaded then
        return
    end
    state.musicPreferenceLoaded = true

    if not hasFilesystemRead() then
        return
    end

    local ok, content = pcall(love.filesystem.read, MUSIC_SETTINGS_FILE)
    if ok and content then
        local saved = parseSavedMusicPreference(content)
        if saved ~= nil then
            ensureAudioSettings().MUSIC = saved
        end
    end
end

local function saveMusicPreference(enabled)
    if not hasFilesystemWrite() then
        return false
    end
    local payload = string.format("return {MUSIC = %s}\n", enabled and "true" or "false")
    local ok = pcall(love.filesystem.write, MUSIC_SETTINGS_FILE, payload)
    return ok == true
end

local function clamp01(value)
    value = tonumber(value) or 0
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

local function computeMusicTargetVolume()
    local cfg = audioConfig()
    if not cfg.musicEnabled then
        return 0
    end

    local volume = clamp01(cfg.musicVolume)
    if state.music.id == "gameplay" then
        volume = volume * clamp01(cfg.gameplayMusicMultiplier)
    end
    if state.music.ducked then
        volume = volume * clamp01(cfg.musicDuckMultiplier)
    end
    return clamp01(volume)
end

local function setSourceVolume(source, volume)
    if source and type(source.setVolume) == "function" then
        pcall(source.setVolume, source, clamp01(volume))
    end
end

local function stopSource(source)
    if source and type(source.stop) == "function" then
        pcall(source.stop, source)
    end
end

local function playSource(source)
    if source and type(source.play) == "function" then
        return pcall(source.play, source) == true
    end
    return false
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
    loadMusicPreference()
    state.initialized = true
    sampleActiveSourceCount("init")
end

function audioRuntime.playMusic(id, path, opts)
    opts = opts or {}
    local musicId = tostring(id or path or "")
    local musicPath = tostring(path or "")
    if musicId == "" or musicPath == "" then
        return false
    end

    if state.music.id == musicId and state.music.path == musicPath and state.music.source then
        state.music.targetVolume = computeMusicTargetVolume()
        return true
    end

    stopSource(state.music.source)

    local ok, source = pcall(love.audio.newSource, musicPath, "stream")
    if not ok or not source then
        state.music.id = nil
        state.music.path = nil
        state.music.source = nil
        state.music.currentVolume = 0
        state.music.targetVolume = 0
        return false
    end

    if type(source.setLooping) == "function" then
        pcall(source.setLooping, source, opts.loop ~= false)
    end
    if type(source.seek) == "function" then
        pcall(source.seek, source, 0)
    end

    state.music.id = musicId
    state.music.path = musicPath
    state.music.source = source
    state.music.currentVolume = 0
    state.music.targetVolume = computeMusicTargetVolume()
    setSourceVolume(source, 0)

    local played = playSource(source)
    if played then
        audioRuntime.notePlayback(musicPath, {category = "music"})
    end
    return played
end

function audioRuntime.playMenuMusic()
    return audioRuntime.playMusic("menu", "assets/audio/MenuTheme.mp3", {loop = true})
end

function audioRuntime.playGameplayMusic()
    return audioRuntime.playMusic("gameplay", "assets/audio/GameplayTheme.mp3", {loop = true})
end

function audioRuntime.setMusicDucked(ducked, reason)
    local normalized = ducked == true
    if state.music.ducked ~= normalized or state.music.duckReason ~= reason then
        state.music.ducked = normalized
        state.music.duckReason = normalized and tostring(reason or "ducked") or nil
    end
    state.music.targetVolume = computeMusicTargetVolume()
    return state.music.targetVolume
end

function audioRuntime.isMusicEnabled()
    return audioConfig().musicEnabled == true
end

function audioRuntime.setMusicEnabled(enabled, opts)
    local options = opts or {}
    ensureAudioSettings().MUSIC = enabled ~= false
    state.music.targetVolume = computeMusicTargetVolume()
    if SETTINGS.AUDIO.MUSIC == false then
        state.music.currentVolume = 0
        setSourceVolume(state.music.source, 0)
    end
    if options.persist ~= false then
        saveMusicPreference(SETTINGS.AUDIO.MUSIC ~= false)
    end
    return SETTINGS.AUDIO.MUSIC
end

function audioRuntime.toggleMusicEnabled()
    return audioRuntime.setMusicEnabled(not audioRuntime.isMusicEnabled())
end

function audioRuntime.update(dt)
    local music = state.music
    if not music.source then
        return
    end

    music.targetVolume = computeMusicTargetVolume()
    local cfg = audioConfig()
    local fadeSec = music.currentVolume <= 0.001 and cfg.musicFadeInSec or cfg.musicFadeSec
    fadeSec = math.max(0.01, tonumber(fadeSec) or 0.45)
    local step = math.min(1, math.max(0, tonumber(dt) or 0) / fadeSec)
    music.currentVolume = music.currentVolume + ((music.targetVolume or 0) - (music.currentVolume or 0)) * step

    if math.abs((music.currentVolume or 0) - (music.targetVolume or 0)) < 0.001 then
        music.currentVolume = music.targetVolume
    end
    setSourceVolume(music.source, music.currentVolume)
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
