package.path = package.path .. ";./?.lua"

local inputActions = require("input_actions")
local inputBindings = require("input_bindings")

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

runTest("triggers_map_to_confirm", function()
    local gamepad = ((inputBindings or {}).gamepad or {})
    local triggerAxes = gamepad.triggerAxesToAction or {}
    local buttons = gamepad.buttonToAction or {}
    assertTrue(triggerAxes.triggerleft == inputActions.CONFIRM.id, "triggerleft axis must map to CONFIRM")
    assertTrue(triggerAxes.triggerright == inputActions.CONFIRM.id, "triggerright axis must map to CONFIRM")
    assertTrue(buttons.a == inputActions.CONFIRM.id, "A must map to CONFIRM")
    assertTrue(buttons.start == inputActions.CODEX_TOGGLE.id, "Start must map to CODEX_TOGGLE")
end)

runTest("steam_input_codex_toggle_maps_to_c", function()
    local steamInput = (inputBindings or {}).steamInput or {}
    local digital = steamInput.digitalActionToAction or {}
    local actionToKey = inputBindings.actionToKey or {}
    assertTrue(digital.codex_toggle == inputActions.CODEX_TOGGLE.id, "Steam Input codex_toggle must map to CODEX_TOGGLE")
    assertTrue(actionToKey[inputActions.CODEX_TOGGLE.id] == "c", "CODEX_TOGGLE must resolve to key c")
end)

runTest("steam_input_manifest_binds_escape_button_to_codex_toggle", function()
    local manifest = io.open("steam_input_manifest.vdf", "r")
    assertTrue(manifest ~= nil, "steam_input_manifest.vdf not readable")
    local manifestContent = manifest:read("*a")
    manifest:close()
    assertTrue(manifestContent:find('"codex_toggle"', 1, true) ~= nil, "manifest missing codex_toggle action")

    local vdf = io.open("steam_input_neptune_controller.vdf", "r")
    assertTrue(vdf ~= nil, "steam_input_neptune_controller.vdf not readable")
    local vdfContent = vdf:read("*a")
    vdf:close()
    assertTrue(vdfContent:find('"button_b"', 1, true) ~= nil, "Steam Deck config missing button_b")
    assertTrue(vdfContent:find('"button_escape"', 1, true) ~= nil, "Steam Deck config missing button_escape")
    assertTrue(vdfContent:find('"left_bumper"', 1, true) ~= nil, "Steam Deck config missing left_bumper")
    assertTrue(vdfContent:find('"right_bumper"', 1, true) ~= nil, "Steam Deck config missing right_bumper")
    assertTrue(vdfContent:find('game_action global_controls cancel', 1, true) ~= nil, "button_b should stay cancel")
    assertTrue(vdfContent:find('game_action global_controls codex_toggle', 1, true) ~= nil, "button_escape should bind codex_toggle")
    assertTrue(vdfContent:find('game_action global_controls tab_left', 1, true) ~= nil, "left_bumper should bind tab_left")
    assertTrue(vdfContent:find('game_action global_controls tab_right', 1, true) ~= nil, "right_bumper should bind tab_right")
    local _, triggerConfirmCount = vdfContent:gsub('game_action global_controls confirm', '')
    assertTrue(triggerConfirmCount >= 3, "Steam Deck config should bind confirm to A plus both triggers")
end)

runTest("right_stick_up_maps_page_up", function()
    local axes = (((inputBindings or {}).gamepad or {}).axisToActions) or {}
    local righty = axes.righty or {}
    assertTrue(righty.negative == inputActions.PAGE_UP.id, "righty negative must map to PAGE_UP")
end)

runTest("right_stick_down_maps_page_down", function()
    local axes = (((inputBindings or {}).gamepad or {}).axisToActions) or {}
    local righty = axes.righty or {}
    assertTrue(righty.positive == inputActions.PAGE_DOWN.id, "righty positive must map to PAGE_DOWN")
end)

runTest("steam_input_left_stick_up_maps_nav_up", function()
    local steamInput = (inputBindings or {}).steamInput or {}
    local navigate = (steamInput.analogActionToNavigation or {}).navigate or {}
    local yAxis = navigate.y or {}
    assertTrue(yAxis.positive == inputActions.NAV_UP.id, "steam input positive Y must map to NAV_UP")
end)

runTest("steam_input_left_stick_down_maps_nav_down", function()
    local steamInput = (inputBindings or {}).steamInput or {}
    local navigate = (steamInput.analogActionToNavigation or {}).navigate or {}
    local yAxis = navigate.y or {}
    assertTrue(yAxis.negative == inputActions.NAV_DOWN.id, "steam input negative Y must map to NAV_DOWN")
end)

runTest("steam_input_right_stick_up_maps_page_up", function()
    local steamInput = (inputBindings or {}).steamInput or {}
    local pageScroll = (steamInput.analogActionToNavigation or {}).page_scroll or {}
    local yAxis = pageScroll.y or {}
    assertTrue(yAxis.positive == inputActions.PAGE_UP.id, "steam input positive page_scroll Y must map to PAGE_UP")
end)

runTest("steam_input_right_stick_down_maps_page_down", function()
    local steamInput = (inputBindings or {}).steamInput or {}
    local pageScroll = (steamInput.analogActionToNavigation or {}).page_scroll or {}
    local yAxis = pageScroll.y or {}
    assertTrue(yAxis.negative == inputActions.PAGE_DOWN.id, "steam input negative page_scroll Y must map to PAGE_DOWN")
end)

runTest("trigger_axis_does_not_emit_page_actions", function()
    local gamepad = (inputBindings or {}).gamepad or {}
    local axes = gamepad.axisToActions or {}
    local ignoredAxes = gamepad.ignoredAxes or {}
    local triggerAxes = gamepad.triggerAxesToAction or {}

    assertTrue(ignoredAxes.lefttrigger == true, "lefttrigger must be ignored axis")
    assertTrue(ignoredAxes.righttrigger == true, "righttrigger must be ignored axis")
    assertTrue(axes.lefttrigger == nil, "lefttrigger must not map to an action")
    assertTrue(axes.righttrigger == nil, "righttrigger must not map to an action")
    assertTrue(axes.triggerleft == nil, "triggerleft must not map to an action")
    assertTrue(axes.triggerright == nil, "triggerright must not map to an action")
    assertTrue(triggerAxes.triggerleft == inputActions.CONFIRM.id, "triggerleft confirm axis binding must exist")
    assertTrue(triggerAxes.triggerright == inputActions.CONFIRM.id, "triggerright confirm axis binding must exist")
end)

runTest("no_duplicate_confirm_from_lt_rt", function()
    local axes = (((inputBindings or {}).gamepad or {}).axisToActions) or {}
    for axisName, axisMap in pairs(axes) do
        if type(axisMap) == "table" then
            assertTrue(axisMap.negative ~= inputActions.CONFIRM.id, axisName .. " negative must not map to CONFIRM")
            assertTrue(axisMap.positive ~= inputActions.CONFIRM.id, axisName .. " positive must not map to CONFIRM")
        end
    end
end)

runTest("state_machine_one_shot_actions_do_not_enter_repeat_set", function()
    local content = readFile("stateMachine.lua")
    assertTrue(type(content) == "string", "stateMachine.lua not readable")
    assertTrue(content:find("local REPEATABLE_ACTIONS =", 1, true) ~= nil, "repeatable action set missing")
    assertTrue(content:find("NAV_UP = true", 1, true) ~= nil, "NAV_UP should remain repeatable")
    assertTrue(content:find("CONFIRM = true", 1, true) == nil, "CONFIRM must not be repeatable")
    assertTrue(content:find("CODEX_TOGGLE = true", 1, true) == nil, "CODEX_TOGGLE must not be repeatable")
    assertTrue(content:find("CANCEL = true", 1, true) == nil, "CANCEL must not be repeatable")
end)

runTest("state_machine_resets_transient_inputs_on_state_change", function()
    local content = readFile("stateMachine.lua")
    assertTrue(type(content) == "string", "stateMachine.lua not readable")
    assertTrue(content:find("local function resetTransientInputState()", 1, true) ~= nil, "transient input reset helper missing")
    assertTrue(content:find("latchedOneShotInputs = {}", 1, true) ~= nil, "one-shot latch reset missing")
    assertTrue(content:find("resetTransientInputState()", 1, true) ~= nil, "state change should call transient input reset")
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
    end
end

print("# Input Smoke Report")
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

local failed = #results - passed
os.exit((failed == 0) and 0 or 1)
