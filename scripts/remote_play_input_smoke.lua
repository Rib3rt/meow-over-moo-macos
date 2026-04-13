package.path = package.path .. ';./?.lua'

local results = {}

local function runTest(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = {name = name, ok = ok, err = err}
end

local function assertTrue(condition, message)
    if not condition then
        error(message or 'assertTrue failed', 2)
    end
end

local function readFile(path)
    local file = io.open(path, 'r')
    if not file then
        return nil
    end
    local content = file:read('*a')
    file:close()
    return content
end

runTest('state_machine_accepts_joystick_fallback_events', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('function stateMachine.joystickpressed', 1, true) ~= nil, 'joystickpressed handler missing')
    assertTrue(content:find('function stateMachine.joystickreleased', 1, true) ~= nil, 'joystickreleased handler missing')
    assertTrue(content:find('function stateMachine.joystickaxis', 1, true) ~= nil, 'joystickaxis handler missing')
    assertTrue(content:find('function stateMachine.joystickhat', 1, true) ~= nil, 'joystickhat handler missing')
end)

runTest('non_gamepad_joystick_maps_to_nav_confirm_cancel', function()
    local bindings = readFile('input_bindings.lua')
    local machine = readFile('stateMachine.lua')
    assertTrue(type(bindings) == 'string', 'input_bindings.lua not readable')
    assertTrue(type(machine) == 'string', 'stateMachine.lua not readable')
    assertTrue(bindings:find('joystick = {', 1, true) ~= nil, 'joystick bindings missing')
    assertTrue(bindings:find('[1] = actionId(ACTIONS.CONFIRM)', 1, true) ~= nil, 'joystick confirm binding missing')
    assertTrue(bindings:find('[2] = actionId(ACTIONS.CANCEL)', 1, true) ~= nil, 'joystick cancel binding missing')
    assertTrue(machine:find('actionByDirection = {', 1, true) ~= nil, 'joystick hat direction mapping missing')
end)

runTest('remote_play_direct_input_events_dispatch_to_actions', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('processRemotePlayDirectInputEvent', 1, true) ~= nil, 'remote play direct input event processor missing')
    assertTrue(content:find('processRemotePlayMouseMotion', 1, true) ~= nil, 'remote play mouse motion handler missing')
    assertTrue(content:find('processRemotePlayKeyEvent', 1, true) ~= nil, 'remote play key handler missing')
    assertTrue(content:find('stateMachine.dispatchAction(actionId, "pressed", false, source)', 1, true) ~= nil, 'direct input should dispatch actions with source tagging')
end)

runTest('remote_play_steam_input_backend_present', function()
    local bindingsContent = readFile('input_bindings.lua')
    assertTrue(type(bindingsContent) == 'string', 'input_bindings.lua not readable')
    assertTrue(bindingsContent:find('steamInput = {', 1, true) ~= nil, 'steam input bindings missing')
    assertTrue(bindingsContent:find('manifestFile = "steam_input_manifest.vdf"', 1, true) ~= nil, 'steam input manifest binding missing')

    local machineContent = readFile('stateMachine.lua')
    assertTrue(type(machineContent) == 'string', 'stateMachine.lua not readable')
    assertTrue(machineContent:find('processSteamInputBackend', 1, true) ~= nil, 'steam input backend processor missing')
    assertTrue(machineContent:find('steamRuntime.configureSteamInput', 1, true) ~= nil, 'steam input runtime configure hook missing')
    assertTrue(machineContent:find('steamRuntime.pollSteamInputActions', 1, true) ~= nil, 'steam input poll hook missing')
end)

runTest('steam_input_backend_is_app_wide_not_remote_play_only', function()
    local backendContent = readFile('input_backend.lua')
    assertTrue(type(backendContent) == 'string', 'input_backend.lua not readable')
    for _, stateName in ipairs({'mainMenu', 'factionSelect', 'gameplay', 'onlineLobby', 'onlineLeaderboard'}) do
        assertTrue(backendContent:find(stateName, 1, true) ~= nil, 'steam input eligible state missing: ' .. stateName)
    end

    local machineContent = readFile('stateMachine.lua')
    assertTrue(type(machineContent) == 'string', 'stateMachine.lua not readable')
    assertTrue(machineContent:find('inputBackend.shouldUseSteamInputBackend', 1, true) ~= nil, 'state machine should delegate steam input backend selection')
end)

runTest('remote_play_steam_input_source_kinds_present', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('steam_input_host_local', 1, true) ~= nil, 'steam input host-local source kind missing')
    assertTrue(content:find('steam_input_remote_play', 1, true) ~= nil, 'steam input remote source kind missing')
    assertTrue(content:find('normalizedKind == "steam_input_remote_play"', 1, true) ~= nil, 'remote steam input should mark source as remote')
end)

runTest('remote_play_steam_input_prefers_remote_session_id_over_joystick_order', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('local sessionId = tonumber(controller and controller.remotePlaySessionId) or 0', 1, true) ~= nil, 'steam input source classification should read remotePlaySessionId')
    assertTrue(content:find('return steamInputRemoteSource(sessionId)', 1, true) ~= nil, 'steam input remote controllers should classify from remotePlaySessionId')
end)

runTest('remote_play_steam_input_host_local_controllers_hide_mouse_cursor', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('sourceKind == "steam_input_host_local"', 1, true) ~= nil, 'steam input host-local should participate in host cursor policy')
end)

runTest('remote_play_exit_disables_direct_input_cleanly', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('setRemotePlayDirectInputActive(false)', 1, true) ~= nil, 'direct input disable call missing')
    assertTrue(content:find('isRemotePlayInputStateName', 1, true) ~= nil, 'remote play state gate missing')
end)

runTest('remote_play_input_source_tagging_present', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('getCurrentInputSourceContext', 1, true) ~= nil, 'state machine should expose current input source context')
    assertTrue(content:find('remote_play_direct_input', 1, true) ~= nil, 'remote direct input source kind missing')
end)

runTest('remote_play_single_joystick_classified_as_host_local', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    local singleBranchIndex = content:find('#joysticks <= 1 then', 1, true)
    assertTrue(singleBranchIndex ~= nil, 'single joystick branch missing')
    local hostReturnIndex = content:find('return hostControllerSource()', singleBranchIndex, true)
    assertTrue(hostReturnIndex ~= nil, 'single joystick branch should classify as host local')
end)

runTest('remote_play_multi_joystick_split_mapping_stable', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('remotePlayJoystickSourceCache', 1, true) ~= nil, 'joystick source cache missing')
    assertTrue(content:find('chooseDeterministicHostJoystickId', 1, true) ~= nil, 'deterministic host joystick resolver missing')
    assertTrue(content:find('remotePlayJoystickSourceCache.hostJoystickId = hostId', 1, true) ~= nil, 'host joystick cache assignment missing')
    assertTrue(content:find('remotePlayJoystickSourceCache.remoteJoystickIds = remoteIds', 1, true) ~= nil, 'remote joystick cache assignment missing')
end)

runTest('remote_play_direct_input_still_classified_remote', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('normalizedKind == "remote_play_direct_input"', 1, true) ~= nil, 'remote direct input classification missing')
    assertTrue(content:find('return remoteDirectInputSource("joy:" .. currentJoystickId)', 1, true) ~= nil, 'remote joystick classification missing for non-host joystick')
end)

runTest('remote_play_mouse_visibility_not_toggled_by_remote_source', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('local fromHostMouse = sourceKind == "host_local_keyboard_mouse"', 1, true) ~= nil, 'host mouse source gate missing for cursor show')
    assertTrue(content:find('if fromHostMouse and MOUSE_STATE.IS_HIDDEN', 1, true) ~= nil, 'cursor show should be host-mouse only')
    assertTrue(content:find('sourceKind == "steam_input_host_local"', 1, true) ~= nil, 'steam input host-local should be included in cursor hide gate')
end)

runTest('remote_play_cursor_assets_scale_with_guest_resolution', function()
    local nativeContent = readFile('integrations/steam/native/steam_bridge.cpp')
    assertTrue(type(nativeContent) == 'string', 'steam_bridge.cpp not readable')
    assertTrue(nativeContent:find('buildLightArrowCursor(32)', 1, true) ~= nil, '32px remote play cursor asset missing')
    assertTrue(nativeContent:find('buildLightArrowCursor(48)', 1, true) ~= nil, '48px remote play cursor asset missing')
    assertTrue(nativeContent:find('buildLightArrowCursor(64)', 1, true) ~= nil, '64px remote play cursor asset missing')
    assertTrue(nativeContent:find('BGetSessionClientResolution', 1, true) ~= nil, 'cursor selection should query guest resolution')
    assertTrue(nativeContent:find('CreateMouseCursor(16, 16', 1, true) == nil, 'legacy 16px visible cursor should be removed')
end)

runTest('remote_play_cursor_uses_bridge_methods_and_mouse_only_policy', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('setRemotePlayCursorVisibility', 1, true) ~= nil, 'remote cursor visibility helper missing')
    assertTrue(content:find('setRemotePlayCursorKind', 1, true) ~= nil, 'remote cursor kind helper missing')
    assertTrue(content:find('setRemotePlayCursorPosition', 1, true) ~= nil, 'remote cursor position helper missing')
    assertTrue(content:find('syncRemotePlayCursorForMouseInput', 1, true) ~= nil, 'remote cursor sync should exist for mouse input')
    assertTrue(content:find('noteRemotePlayNonMouseInput(event.sessionId)', 1, true) ~= nil, 'controller/key input should still hide remote cursor')
    assertTrue(content:find('remotePlayCursorInputModeBySession[normalized] = "mouse"', 1, true) ~= nil, 'mouse input should mark that session cursor as mouse-driven')
    assertTrue(content:find('remotePlayCursorInputModeBySession[normalized] = "non_mouse"', 1, true) ~= nil, 'non-mouse input should hide only that session cursor')
end)

runTest('remote_play_cursor_visibility_decoupled_from_action_authority', function()
    local stateMachineContent = readFile('stateMachine.lua')
    assertTrue(type(stateMachineContent) == 'string', 'stateMachine.lua not readable')
    assertTrue(stateMachineContent:find('return remotePlayCursorInputModeBySession[normalized] == "mouse"', 1, true) ~= nil, 'cursor visibility should depend on actual mouse use')

    local gameplayContent = readFile('gameplay.lua')
    assertTrue(type(gameplayContent) == 'string', 'gameplay.lua not readable')
    assertTrue(gameplayContent:find('function gameplay.shouldShowRemotePlayCursor()', 1, true) ~= nil, 'legacy helper should still exist for compatibility')
    assertTrue(gameplayContent:find('return canCurrentInputIssueActions()', 1, true) ~= nil, 'gameplay action authority should remain separate from cursor visibility')
end)

runTest('steam_input_suppresses_love_controller_callbacks_when_handles_active', function()
    local content = readFile('stateMachine.lua')
    assertTrue(type(content) == 'string', 'stateMachine.lua not readable')
    assertTrue(content:find('shouldSuppressLoveControllerCallbacks', 1, true) ~= nil, 'love controller suppression helper missing')
    for _, marker in ipairs({
        'function stateMachine.gamepadpressed',
        'function stateMachine.gamepadreleased',
        'function stateMachine.gamepadaxis',
        'function stateMachine.joystickpressed',
        'function stateMachine.joystickreleased',
        'function stateMachine.joystickaxis',
        'function stateMachine.joystickhat'
    }) do
        local startIndex = content:find(marker, 1, true)
        assertTrue(startIndex ~= nil, 'missing controller handler: ' .. marker)
        local suppressIndex = content:find('if shouldSuppressLoveControllerCallbacks() then', startIndex, true)
        assertTrue(suppressIndex ~= nil, 'controller handler should honor steam input suppression: ' .. marker)
    end
end)

runTest('remote_play_state_entry_hides_os_cursor_by_default', function()
    local machineContent = readFile('stateMachine.lua')
    assertTrue(type(machineContent) == 'string', 'stateMachine.lua not readable')
    assertTrue(machineContent:find('local function applyRemotePlayCursorPolicyForState', 1, true) ~= nil, 'remote play cursor policy helper missing')
    assertTrue(machineContent:find('love.mouse.setVisible(false)', 1, true) ~= nil, 'remote play cursor policy should hide OS cursor')
    assertTrue(machineContent:find('applyRemotePlayCursorPolicyForState(currentStateName)', 1, true) ~= nil, 'state change should apply remote play cursor policy')

    local gameplayContent = readFile('gameplay.lua')
    assertTrue(type(gameplayContent) == 'string', 'gameplay.lua not readable')
    assertTrue(gameplayContent:find('if isRemotePlayLocalMode() then', 1, true) ~= nil, 'gameplay enter should branch remote play cursor policy')
    assertTrue(gameplayContent:find('MOUSE_STATE.IS_HIDDEN = true', 1, true) ~= nil, 'gameplay enter should keep cursor hidden in remote play')
end)

runTest('remote_play_strict_split_uses_player2_identity_not_sequence_position', function()
    local content = readFile('gameplay.lua')
    assertTrue(type(content) == 'string', 'gameplay.lua not readable')
    assertTrue(content:find('tonumber(metadata and metadata.slot) == 2', 1, true) ~= nil, 'player 2 identity should use metadata slot')
    assertTrue(content:find('if controllers.preset_player_2 then', 1, true) ~= nil, 'player 2 identity preset fallback missing')
end)

runTest('remote_play_p2_controls_faction1_turn1_is_actionable_for_remote_source', function()
    local content = readFile('gameplay.lua')
    assertTrue(type(content) == 'string', 'gameplay.lua not readable')
    assertTrue(content:find('local currentFactionControllerId = assignments[gameRuler.currentPlayer]', 1, true) ~= nil, 'turn ownership should resolve from current faction assignment')
    assertTrue(content:find('return tostring(currentFactionControllerId) == playerTwoControllerId', 1, true) ~= nil, 'turn ownership should compare assignment against player2 identity')
end)

runTest('remote_play_strict_split_blocks_host_actions_on_p2_turn', function()
    local content = readFile('gameplay.lua')
    assertTrue(type(content) == 'string', 'gameplay.lua not readable')
    assertTrue(content:find('isCurrentTurnOwnedByPlayerTwoController', 1, true) ~= nil, 'P2 ownership resolver missing')
    assertTrue(content:find('canCurrentInputIssueActions', 1, true) ~= nil, 'strict split action gate missing')
    assertTrue(content:find('if p2Turn then', 1, true) ~= nil, 'strict split should branch on P2-owned turn')
end)

runTest('remote_play_strict_split_blocks_guest_actions_on_p1_turn', function()
    local content = readFile('gameplay.lua')
    assertTrue(type(content) == 'string', 'gameplay.lua not readable')
    assertTrue(content:find('return not remoteInput', 1, true) ~= nil, 'strict split should block remote actions on host-owned turns')
end)

runTest('remote_play_readonly_paths_still_available_when_action_blocked', function()
    local gameplayContent = readFile('gameplay.lua')
    assertTrue(type(gameplayContent) == 'string', 'gameplay.lua not readable')
    assertTrue(gameplayContent:find('handleReadOnlyGridInspect', 1, true) ~= nil, 'read-only grid inspect helper missing')

    local uiContent = readFile('uiClass.lua')
    assertTrue(type(uiContent) == 'string', 'uiClass.lua not readable')
    assertTrue(uiContent:find('handleOnlineNonLocalClick', 1, true) ~= nil, 'read-only click handler missing')
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
    end
end

print('# Remote Play Input Smoke Report')
print('')
print('- Passed: ' .. tostring(passed))
print('- Failed: ' .. tostring(#results - passed))
print('')
for _, result in ipairs(results) do
    local status = result.ok and 'PASS' or 'FAIL'
    print(string.format('- `%s` %s', status, result.name))
    if not result.ok then
        print('  - Error: ' .. tostring(result.err))
    end
end

os.exit((failed == 0) and 0 or 1)
