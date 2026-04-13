package.path = package.path .. ";./?.lua"

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

local function readFile(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function resetModules()
    package.loaded["audio_runtime"] = nil
    package.loaded["soundCache"] = nil
end

local function installLoveAudioStub()
    love = love or {}
    love.audio = love.audio or {}
    love.timer = love.timer or {}

    local now = 100
    local activeSources = 0
    local resumeCalls = 0
    love.timer.getTime = function()
        now = now + 0.25
        return now
    end

    love.audio.newSource = function(path, sourceType)
        local source = {
            __path = path,
            __type = sourceType,
            __volume = 1,
            __pitch = 1,
            __played = 0,
            __isPlaying = false,
        }

        function source:setVolume(value)
            self.__volume = value
        end

        function source:setPitch(value)
            self.__pitch = value
        end

        function source:stop()
            if self.__isPlaying then
                activeSources = math.max(0, activeSources - 1)
                self.__isPlaying = false
            end
        end

        function source:seek()
        end

        function source:play()
            if not self.__isPlaying then
                activeSources = activeSources + 1
                self.__isPlaying = true
            end
            self.__played = self.__played + 1
        end

        function source:clone()
            local copy = {}
            for key, value in pairs(self) do
                copy[key] = value
            end
            copy.__played = 0
            copy.__cloned = true
            copy.__isPlaying = false
            return setmetatable(copy, {__index = source})
        end

        return source
    end

    love.audio.getActiveSourceCount = function()
        return activeSources
    end

    love.audio.resume = function()
        resumeCalls = resumeCalls + 1
        return true
    end

    love.__audio_stub = {
        getActiveSources = function()
            return activeSources
        end,
        getResumeCalls = function()
            return resumeCalls
        end,
    }
end

runTest("sound_cache_play_updates_audio_runtime_diagnostics", function()
    resetModules()
    installLoveAudioStub()
    SETTINGS = {
        AUDIO = {
            SFX = true,
            SFX_VOLUME = 0.4,
            MUSIC = true,
            MUSIC_VOLUME = 0.1,
        }
    }

    local audioRuntime = require("audio_runtime")
    local soundCache = require("soundCache")

    audioRuntime.init()
    audioRuntime.resetRemotePlayWindow("smoke")
    local source = soundCache.play("assets/audio/GenericButton14.wav", {
        clone = false,
        volume = 0.4,
        category = "sfx"
    })
    assertTrue(source ~= nil, "soundCache.play should return a source")

    local diagnostics = audioRuntime.getDiagnostics()
    assertTrue(diagnostics.remotePlayPlaybackSeen == true, "audio runtime should mark remote play playback as seen")
    assertTrue(diagnostics.lastPlaybackPath == "assets/audio/GenericButton14.wav", "audio runtime should record last playback path")
    assertTrue(diagnostics.lastPlaybackCategory == "sfx", "audio runtime should record last playback category")
    assertTrue(diagnostics.remotePlayMatchFirstPlaybackPath == nil, "non-match window should not set match first playback")
    assertTrue(diagnostics.activeSourceCount == 1, "active source count should reflect host-side playback")
end)

runTest("audio_runtime_muted_warning_only_triggers_when_output_is_effectively_silent", function()
    resetModules()
    installLoveAudioStub()
    SETTINGS = {
        AUDIO = {
            SFX = false,
            SFX_VOLUME = 0,
            MUSIC = false,
            MUSIC_VOLUME = 0,
        }
    }

    local audioRuntime = require("audio_runtime")
    audioRuntime.init()
    audioRuntime.resetRemotePlayWindow("muted")
    assertTrue(audioRuntime.consumeRemotePlayMutedWarning() == true, "muted warning should trigger once when output is silent")
    assertTrue(audioRuntime.consumeRemotePlayMutedWarning() == false, "muted warning should be one-shot")

    SETTINGS.AUDIO.SFX = true
    SETTINGS.AUDIO.SFX_VOLUME = 0.5
    audioRuntime.beginRemotePlaySession("audible")
    assertTrue(audioRuntime.consumeRemotePlayMutedWarning() == false, "muted warning should not trigger when SFX output is audible")
end)

runTest("audio_runtime_tracks_first_session_and_match_playback", function()
    resetModules()
    installLoveAudioStub()
    SETTINGS = {
        AUDIO = {
            SFX = true,
            SFX_VOLUME = 0.4,
            MUSIC = true,
            MUSIC_VOLUME = 0.1,
        }
    }

    local audioRuntime = require("audio_runtime")
    local soundCache = require("soundCache")

    audioRuntime.init()
    audioRuntime.beginRemotePlaySession("remote_play_session_connected")
    soundCache.play("assets/audio/GenericButton14.wav", {clone = false, volume = 0.4, category = "sfx"})
    audioRuntime.resetRemotePlayWindow("remote_play_match_start")
    soundCache.play("assets/audio/GenericButton6.wav", {clone = false, volume = 0.4, category = "sfx"})

    local diagnostics = audioRuntime.getDiagnostics()
    assertTrue(diagnostics.remotePlaySessionFirstPlaybackPath == "assets/audio/GenericButton14.wav", "session first playback should be tracked")
    assertTrue(diagnostics.remotePlayMatchFirstPlaybackPath == "assets/audio/GenericButton6.wav", "match first playback should be tracked")
    assertTrue(type(diagnostics.activeSourceCount) == "number", "active source count should be tracked")
end)

runTest("audio_runtime_resume_after_focus_and_visibility_regain_updates_diagnostics", function()
    resetModules()
    installLoveAudioStub()
    SETTINGS = {
        AUDIO = {
            SFX = true,
            SFX_VOLUME = 0.4,
            MUSIC = true,
            MUSIC_VOLUME = 0.1,
        }
    }

    local audioRuntime = require("audio_runtime")
    audioRuntime.init()
    assertTrue(audioRuntime.onFocusChanged(false) == false, "focus lost should report false")
    assertTrue(audioRuntime.onFocusChanged(true) == true, "focus regain should report true")
    assertTrue(audioRuntime.resumeAudioOutput("focus_regained") == true, "resume should succeed with stubbed love.audio.resume")
    assertTrue(audioRuntime.onVisibilityChanged(false) == false, "visibility lost should report false")
    assertTrue(audioRuntime.onVisibilityChanged(true) == true, "visibility regain should report true")
    assertTrue(audioRuntime.resumeAudioOutput("visibility_regained") == true, "resume should succeed on visibility regain")

    local diagnostics = audioRuntime.getDiagnostics()
    assertTrue(diagnostics.focused == true, "focus state should be restored")
    assertTrue(diagnostics.visible == true, "visibility state should be restored")
    assertTrue(type(diagnostics.lastResumeAt) == "number", "resume timestamp should be tracked")
    assertTrue(diagnostics.lastResumeReason == "visibility_regained", "last resume reason should be tracked")
    assertTrue(diagnostics.lastResumeSucceeded == true, "resume result should be tracked")
    assertTrue(type(diagnostics.lastResumeActiveSourceCount) == "number", "resume should sample active source count")
    assertTrue(love.__audio_stub.getResumeCalls() >= 2, "focus/visibility regain should call love.audio.resume")
end)

runTest("audio_runtime_remote_play_entrypoints_resume_and_log_active_sources", function()
    local factionContent = readFile("factionSelect.lua")
    local gameplayContent = readFile("gameplay.lua")
    assertTrue(type(factionContent) == "string", "factionSelect.lua not readable")
    assertTrue(type(gameplayContent) == "string", "gameplay.lua not readable")
    assertTrue(factionContent:find('audioRuntime.resumeAudioOutput("remote_play_session_connected")', 1, true) ~= nil, "session connect should resume audio output")
    assertTrue(factionContent:find('audioRuntime.logRemotePlayWindowSummary("remote_play_session_connected")', 1, true) ~= nil, "session connect should log audio summary")
    assertTrue(gameplayContent:find('audioRuntime.resumeAudioOutput("remote_play_match_start")', 1, true) ~= nil, "match start should resume audio output")
    assertTrue(gameplayContent:find('audioRuntime.logRemotePlayWindowSummary("remote_play_match_start")', 1, true) ~= nil, "match start should log audio summary")
end)

runTest("ui_audio_call_sites_route_through_sound_cache", function()
    for _, fileName in ipairs({
        "gameplay.lua",
        "factionSelect.lua",
        "mainMenu.lua",
        "onlineLobby.lua",
        "onlineLeaderboard.lua",
        "confirmDialog.lua",
        "gameLogViewer.lua",
        "uiClass.lua",
    }) do
        local content = readFile(fileName)
        assertTrue(type(content) == "string", fileName .. " not readable")
        assertTrue(content:find("love.audio.newSource", 1, true) == nil, fileName .. " should not create direct audio sources")
        assertTrue(content:find(":play()", 1, true) == nil, fileName .. " should not play audio directly")
    end
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

print(string.format("audio_runtime_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
