package.path = package.path .. ";./?.lua"

local TEST_SAVE_DIR = "/tmp/resume_smoke_store"
os.execute("mkdir -p " .. TEST_SAVE_DIR)

love = {
    filesystem = {
        write = function(virtualPath, payload)
            local file, err = io.open(TEST_SAVE_DIR .. "/" .. tostring(virtualPath), "w")
            if not file then
                return false, err
            end
            file:write(payload or "")
            file:close()
            return true
        end,
        read = function(virtualPath)
            local file, err = io.open(TEST_SAVE_DIR .. "/" .. tostring(virtualPath), "r")
            if not file then
                return nil, err
            end
            local content = file:read("*a")
            file:close()
            return content
        end,
        remove = function(virtualPath)
            os.remove(TEST_SAVE_DIR .. "/" .. tostring(virtualPath))
            return true
        end,
        getSaveDirectory = function()
            return TEST_SAVE_DIR
        end
    }
}

local resumeStore = require("resume_store")

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

runTest("resume_v4_invalidates_v3_snapshot", function()
    resumeStore.clear("v3_invalid_start")

    local ok = resumeStore.save({
        mode = "singlePlayer",
        snapshot = {marker = "v2"},
        controllers = {},
        controllerSequence = {},
        factionAssignments = {}
    })
    assertTrue(ok == true, "v4 baseline save should succeed")

    local path = TEST_SAVE_DIR .. "/LastIncompleteMatch.dat"
    local file = io.open(path, "w")
    assertTrue(file ~= nil, "should open resume file for legacy write")
    file:write('return {version=3,mode="singlePlayer",snapshot={legacy=true}}\n')
    file:close()

    local envelope, reason = resumeStore.load()
    assertTrue(envelope == nil, "legacy envelope must be rejected")
    assertTrue(tostring(reason) == "invalid_envelope", "legacy rejection reason mismatch")

    local probe = io.open(path, "r")
    assertTrue(probe == nil, "legacy resume file should be cleared automatically")

    resumeStore.clear("v3_invalid_end")
end)

runTest("resume_store_single_slot_overwrites_previous_snapshot", function()
    resumeStore.clear("test_start")

    local ok1 = resumeStore.save({
        mode = "singlePlayer",
        snapshot = {marker = "old"},
        controllers = {},
        controllerSequence = {},
        factionAssignments = {}
    })
    assertTrue(ok1 == true, "first save should succeed")

    local ok2 = resumeStore.save({
        mode = "singlePlayer",
        snapshot = {marker = "new"},
        controllers = {},
        controllerSequence = {},
        factionAssignments = {}
    })
    assertTrue(ok2 == true, "second save should succeed")

    local envelope = resumeStore.load()
    assertTrue(type(envelope) == "table", "envelope should load")
    assertTrue(envelope.snapshot and envelope.snapshot.marker == "new", "newest envelope should overwrite previous")

    resumeStore.clear("test_end")
end)

runTest("resume_prompt_shown_for_matching_mode_unfinished_game", function()
    local content = readFile("mainMenu.lua")
    assertTrue(type(content) == "string", "mainMenu.lua not readable")
    assertTrue(content:find("startModeWithResumePrompt", 1, true) ~= nil, "resume prompt flow helper missing")
    assertTrue(content:find("Continue your last unfinished match%?", 1) ~= nil, "resume prompt text missing")
    assertTrue(content:find('confirmText = "Continue"', 1, true) ~= nil, "continue label missing")
    assertTrue(content:find('cancelText = "New Game"', 1, true) ~= nil, "new game label missing")
end)

runTest("resume_prompt_not_shown_for_mismatched_mode", function()
    resumeStore.clear("mode_mismatch_start")
    resumeStore.save({
        mode = "singlePlayer",
        snapshot = {turn = 3},
        controllers = {},
        controllerSequence = {},
        factionAssignments = {}
    })

    assertTrue(resumeStore.hasMatchingMode("singlePlayer") == true, "matching mode should return true")
    assertTrue(resumeStore.hasMatchingMode("localMultyplayer") == false, "mismatched mode should return false")

    resumeStore.clear("mode_mismatch_end")
end)

runTest("continue_loads_saved_snapshot_into_gameplay", function()
    local mainMenu = readFile("mainMenu.lua")
    local gameplay = readFile("gameplay.lua")
    assertTrue(type(mainMenu) == "string", "mainMenu.lua not readable")
    assertTrue(type(gameplay) == "string", "gameplay.lua not readable")

    assertTrue(mainMenu:find('GAME.CURRENT.PENDING_RESUME_SNAPSHOT = envelope.snapshot', 1, true) ~= nil, "main menu continue should stage pending snapshot")
    assertTrue(mainMenu:find('stateMachineRef.changeState("gameplay")', 1, true) ~= nil, "continue should route to gameplay")
    assertTrue(gameplay:find('GAME.CURRENT.PENDING_RESUME_SNAPSHOT', 1, true) ~= nil, "gameplay resume boot path missing")
    assertTrue(gameplay:find('gameRuler:loadResumeSnapshot', 1, true) ~= nil, "gameplay should load resume snapshot")
end)

runTest("new_game_from_prompt_clears_snapshot_and_routes_faction_select", function()
    local content = readFile("mainMenu.lua")
    assertTrue(type(content) == "string", "mainMenu.lua not readable")
    assertTrue(content:find('resumeStore.clear("new_game_selected")', 1, true) ~= nil, "new game branch should clear stored snapshot")
    assertTrue(content:find('stateMachineRef.changeState("factionSelect")', 1, true) ~= nil, "new game branch should route to faction select")
end)

runTest("snapshot_cleared_on_proper_gameover", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('clearResumeSnapshot("game_over_phase")', 1, true) ~= nil, "phase transition to gameOver should clear resume")
    assertTrue(content:find('clearResumeSnapshot("gameplay_exit_game_over")', 1, true) ~= nil, "gameplay exit at gameOver should clear resume")
end)

runTest("resume_dirty_on_each_successful_local_action", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('"local_action"', 1, true) ~= nil, "per-action resume dirty marker missing")
    assertTrue(content:find('isResumeCheckpointAction', 1, true) ~= nil, "resume checkpoint action helper missing")
    assertTrue(content:find('actionType == "end_turn"', 1, true) ~= nil, "end-turn checkpoint action missing")
    assertTrue(content:find('actionType == "confirmCommandHub"', 1, true) ~= nil, "confirmCommandHub checkpoint action missing")
    assertTrue(content:find('actionType == "confirmDeployment"', 1, true) ~= nil, "confirmDeployment checkpoint action missing")
    assertTrue(content:find('actionType == "placeAllNeutralBuildings"', 1, true) ~= nil, "placeAllNeutralBuildings checkpoint action missing")
    assertTrue(content:find('RESUME_MIN_WRITE_INTERVAL_SEC = 0.35', 1, true) ~= nil, "minimum write interval guard missing")
end)

runTest("manual_escape_exit_single_local_sets_no_save_flag", function()
    local gameplay = readFile("gameplay.lua")
    assertTrue(type(gameplay) == "string", "gameplay.lua not readable")
    assertTrue(gameplay:find('manualNoSaveExitRequested = isResumeSupportedMode()', 1, true) ~= nil, "manual no-save flag assignment missing")
    assertTrue(gameplay:find('gameRuler.currentPhase ~= "gameOver"', 1, true) ~= nil, "manual no-save guard should exclude gameOver phase")
    assertTrue(gameplay:find('clearResumeSnapshot("manual_exit_no_save")', 1, true) ~= nil, "manual no-save exit should clear snapshot")
end)

runTest("manual_escape_exit_dialog_text_mentions_not_saved", function()
    local gameplay = readFile("gameplay.lua")
    assertTrue(type(gameplay) == "string", "gameplay.lua not readable")
    assertTrue(gameplay:find("Return to main menu%? Progress will be lost and not saved%.", 1) ~= nil, "manual exit warning text missing")
end)

runTest("online_mode_never_writes_resume_snapshot", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('return gameMode == GAME.MODE.SINGLE_PLAYER or gameMode == GAME.MODE.MULTYPLAYER_LOCAL', 1, true) ~= nil, "resume mode guard should exclude online mode")
end)

runTest("resume_snapshot_payload_excludes_turnlog_and_heavy_stats", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")
    assertTrue(content:find('version = 4', 1, true) ~= nil, "snapshot version should be 4")
    assertTrue(content:find('turnLog = copySerializable', 1, true) == nil, "turnLog should not be serialized in compact resume snapshot")
    assertTrue(content:find('gameStats = copySerializable', 1, true) == nil, "gameStats should not be serialized in compact resume snapshot")
    assertTrue(content:find('gameTimer = copySerializable', 1, true) == nil, "gameTimer should not be serialized in compact resume snapshot")
    assertTrue(content:find('integritySignature', 1, true) ~= nil, "integrity signature should be part of snapshot payload")
end)

runTest("resume_restore_integrity_requires_both_commandants_and_matching_unit_count", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")
    assertTrue(content:find('if expectedBoardUnits ~= placedBoardUnits then', 1, true) ~= nil, "board unit integrity guard missing")
    assertTrue(content:find('board_unit_count_mismatch', 1, true) ~= nil, "board mismatch error reason missing")
    assertTrue(content:find('commandant_integrity_failed', 1, true) ~= nil, "commandant integrity failure reason missing")
    assertTrue(content:find('integrity_signature_mismatch', 1, true) ~= nil, "integrity signature mismatch failure reason missing")
end)

runTest("resume_restore_rehydrates_units_from_template_fields", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")
    assertTrue(content:find('local template = unitsInfo:getUnitInfo(unitName)', 1, true) ~= nil, "template rehydration lookup missing")
    assertTrue(content:find('for key, value in pairs(template) do', 1, true) ~= nil, "rehydration should copy template sprite/combat fields")
end)


runTest("resume_restore_failure_shows_resume_unavailable_message", function()
    local mainMenu = readFile("mainMenu.lua")
    local gameplay = readFile("gameplay.lua")
    assertTrue(type(mainMenu) == "string", "mainMenu.lua not readable")
    assertTrue(type(gameplay) == "string", "gameplay.lua not readable")
    assertTrue(mainMenu:find('Resume Unavailable', 1, true) ~= nil, "Resume Unavailable title missing")
    assertTrue(mainMenu:find('ConfirmDialog.showMessage', 1, true) ~= nil, "single-button resume message helper missing")
    assertTrue(gameplay:find('GAME.CURRENT.RESUME_RESTART_NOTICE', 1, true) ~= nil, "gameplay should queue resume restart notice on restore failure")
end)

runTest("resume_exit_does_not_force_unstable_write", function()
    local gameplay = readFile("gameplay.lua")
    assertTrue(type(gameplay) == "string", "gameplay.lua not readable")
    assertTrue(gameplay:find('saveResumeSnapshot("gameplay_exit_forced")', 1, true) == nil, "forced gameplay-exit save should be removed")
    assertTrue(gameplay:find('gameplay_exit skipped unstable flush', 1, true) ~= nil, "unstable exit skip log missing")
end)

runTest("game_ruler_exposes_resume_snapshot_methods", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")
    assertTrue(content:find('function gameRuler:buildResumeSnapshot()', 1, true) ~= nil, "buildResumeSnapshot missing")
    assertTrue(content:find('function gameRuler:loadResumeSnapshot(snapshot)', 1, true) ~= nil, "loadResumeSnapshot missing")
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

print(string.format("resume_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
