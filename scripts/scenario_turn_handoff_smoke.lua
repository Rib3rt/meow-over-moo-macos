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

local function localBlock(content, marker, maxLength)
    local startIndex = content:find(marker, 1, true)
    assertTrue(startIndex ~= nil, marker .. " missing")
    return content:sub(startIndex, startIndex + (maxLength or 800))
end

runTest("scenario_command_hub_defense_uses_normal_gameplay_cadence", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")

    local standardTiming = localBlock(content, "local STANDARD_COMMAND_HUB_DEFENSE_TIMING", 500)
    assertTrue(standardTiming:find("startDelay = 0.1", 1, true) ~= nil, "standard Commandant Defense start timing should remain unchanged")
    assertTrue(standardTiming:find("scanStepDelay = 0.4", 1, true) ~= nil, "standard Commandant Defense scan timing should remain unchanged")
    assertTrue(standardTiming:find("completeDelay = 0.5", 1, true) ~= nil, "standard Commandant Defense completion timing should remain unchanged")

    local scenarioTiming = localBlock(content, "local SCENARIO_COMMAND_HUB_DEFENSE_TIMING", 700)
    assertTrue(scenarioTiming:find("startDelay = 0", 1, true) ~= nil, "Scenario Commandant Defense should start immediately after Red handoff")
    assertTrue(scenarioTiming:find("missingHubDelay = 0", 1, true) ~= nil, "Scenario Commandant Defense should not add a missing-hub pause")
    assertTrue(scenarioTiming:find("missingHubPositionDelay = 0", 1, true) ~= nil, "Scenario Commandant Defense should not add a missing-position pause")
    assertTrue(scenarioTiming:find("scanStepDelay = 0.4", 1, true) ~= nil, "Scenario Commandant Defense should scan cells with normal cadence")
    assertTrue(scenarioTiming:find("completeDelay = 0", 1, true) ~= nil, "Scenario Commandant Defense should not add a silent tail before Red Policy")
    assertTrue(scenarioTiming:find("destroyEvaluateDelay = 0", 1, true) ~= nil, "Scenario Commandant Defense should not delay scenario outcome checks")

    assertTrue(content:find("function gameRuler:getCommandHubDefenseTiming()", 1, true) ~= nil, "mode-specific Commandant Defense timing helper missing")
    assertTrue(content:find("return SCENARIO_COMMAND_HUB_DEFENSE_TIMING", 1, true) ~= nil, "Scenario Mode should select explicit Commandant Defense timing")
    assertTrue(content:find("return STANDARD_COMMAND_HUB_DEFENSE_TIMING", 1, true) ~= nil, "non-scenario modes should keep standard Commandant Defense timing")
    assertTrue(content:find("if commandHubStartDelay <= 0 then", 1, true) ~= nil, "zero-delay Scenario Commandant Defense should execute immediately, not via scheduledActions")
    assertTrue(content:find("if scenarioMode and self.currentPlayer == 1 then", 1, true) ~= nil, "Blue Scenario turns should skip Commandant Defense")
    assertTrue(content:find("self.currentTurnPhase = TURN_PHASES.ACTIONS", 1, true) ~= nil, "Blue Scenario turns should enter actions directly")
    assertTrue(content:find("blocked = self:isScenarioTurnHandoffBlocked()", 1, true) ~= nil, "Scenario Commandant Defense should not wait on residual visual particles")
    assertTrue(content:find("function gameRuler:isScenarioRedPolicyAnimationBlocked()", 1, true) ~= nil, "Scenario Red Policy should have a mode-specific animation gate")
    assertTrue(content:find("hasActiveScenarioPolicyBlockingAnimations", 1, true) ~= nil, "Scenario Red Policy gate should defer to grid-level blocking classification")
    assertTrue(content:find("function gameRuler:isScenarioTurnHandoffBlocked()", 1, true) ~= nil, "Scenario turn handoff should have a dedicated animation gate")
    assertTrue(content:find("hasActiveScenarioTurnHandoffAnimations", 1, true) ~= nil, "Scenario handoff gate should defer to grid-level blocking classification")
    assertTrue(content:find("function gameRuler:hasScenarioTurnHandoffBlockingScheduledActions()", 1, true) ~= nil, "Scenario handoff should classify scheduled work instead of blocking on every scheduled action")
    assertTrue(content:find("scenarioTurnHandoffBlocking", 1, true) ~= nil, "Scenario handoff blocking scheduled work should be explicitly tagged")
end)

runTest("scenario_red_policy_has_no_post_handoff_delay", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("scenarioRedVisibleDelaySec = 0", 1, true) ~= nil, "Scenario Red Policy should not add a post-handoff delay")
    assertTrue(content:find("scenarioRedPreviewDelaySec = 0.35", 1, true) ~= nil, "Scenario Red Policy should pause briefly on visible action preview")
    assertTrue(content:find("scenarioRedVisibleDelaySec = 0.85", 1, true) == nil, "old Scenario Red Policy handoff delay must not return")
    assertTrue(content:find("Scenario Mode uses the verified Scenario Red Policy runtime", 1, true) ~= nil, "Scenario runtime policy path should be explicit")
    assertTrue(content:find("not gameRuler:isScenarioRedPolicyAnimationBlocked()", 1, true) ~= nil, "Scenario Red Policy should not be blocked by non-blocking Commandant Defense visuals")
    assertTrue(content:find("if gameMode ~= GAME.MODE.SCENARIO and aiPlayer", 1, true) ~= nil, "standard AI should stay outside Scenario Mode")
    assertTrue(content:find("not gameRuler:isScenarioTurnHandoffBlocked()", 1, true) ~= nil, "Scenario handoff should not wait for residual visual effects")
end)

runTest("commandant_defense_visuals_are_non_blocking_only_for_scenario_policy", function()
    local content = readFile("playGridClass.lua")
    assertTrue(type(content) == "string", "playGridClass.lua not readable")

    local helper = localBlock(content, "function playGridClass:hasActiveScenarioPolicyBlockingAnimations()", 1200)
    assertTrue(helper:find("movingUnits", 1, true) ~= nil, "real movement should still block Scenario Red Policy")
    assertTrue(helper:find("rangedAttackEffects", 1, true) ~= nil, "real ranged attacks should still block Scenario Red Policy")
    assertTrue(helper:find('effect.source ~= "command_hub_defense"', 1, true) ~= nil, "Commandant Defense visuals should be classified separately")
    assertTrue(helper:find("commandHubScanEffects", 1, true) == nil, "Commandant scan visuals should not block Scenario Red Policy")
    assertTrue(helper:find("commandHubZoomEffects", 1, true) == nil, "Commandant zoom visuals should not block Scenario Red Policy")

    assertTrue(content:find('source = "command_hub_defense"', 1, true) ~= nil, "Commandant Defense effects should be tagged for non-blocking policy handoff")
end)

runTest("scenario_turn_handoff_waits_for_real_action_resolution_only", function()
    local content = readFile("playGridClass.lua")
    assertTrue(type(content) == "string", "playGridClass.lua not readable")

    local helper = localBlock(content, "function playGridClass:hasActiveScenarioTurnHandoffAnimations()", 900)
    assertTrue(helper:find("movingUnits", 1, true) ~= nil, "Scenario handoff should wait for movement animations")
    assertTrue(helper:find("rangedAttackEffects", 1, true) ~= nil, "Scenario handoff should wait for ranged attack flight")
    assertTrue(helper:find("activeEffects", 1, true) == nil, "Scenario handoff should not wait for legacy placement effects")
    assertTrue(helper:find("destructionEffects", 1, true) == nil, "Scenario handoff should not wait for residual destruction particles")
    assertTrue(helper:find("impactEffects", 1, true) == nil, "Scenario handoff should not wait for residual impact particles")
    assertTrue(helper:find("commandHubScanEffects", 1, true) == nil, "Scenario handoff should not wait for Commandant scan visuals")
end)

runTest("scenario_action_resolution_schedules_only_real_handoff_blockers", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")

    assertTrue(content:find("SCENARIO_TURN_HANDOFF_BLOCKING_ACTION", 1, true) ~= nil, "Scenario action-resolution schedule tag missing")
    assertTrue(content:find("self:scheduleAction(impactDelay, resolveBeamDamage, SCENARIO_TURN_HANDOFF_BLOCKING_ACTION)", 1, true) ~= nil, "beam damage resolution must block handoff until damage is applied")
    assertTrue(content:find("self:executeUnitMovement(fromRow, fromCol, targetRow, targetCol, true)", 1, true) ~= nil, "melee kill capture path missing")
    assertTrue(content:find("end, SCENARIO_TURN_HANDOFF_BLOCKING_ACTION)", 1, true) ~= nil, "Scenario capture/projectile/commandant resolution schedules should be tagged")

    local handoff = localBlock(content, "function gameRuler:isScenarioTurnHandoffBlocked()", 900)
    assertTrue(handoff:find("hasScenarioTurnHandoffBlockingScheduledActions()", 1, true) ~= nil, "Scenario handoff should wait only for tagged scheduled resolution work")
    assertTrue(handoff:find("self.scheduledActions and #self.scheduledActions", 1, true) == nil, "Scenario handoff must not block on every scheduled action")
end)

runTest("scenario_conquest_rechecks_stalled_units_after_capture", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")

    local movement = localBlock(content, "function gameRuler:executeUnitMovement", 2600)
    assertTrue(movement:find("if not isConquerAction or self:isScenarioMode() then", 1, true) ~= nil, "Scenario conquest moves must re-check stalled units after capture completes")
    assertTrue(movement:find("self:checkForStalledUnits()", 1, true) ~= nil, "movement completion should run stalled-unit detection")

    local stalled = localBlock(content, "function gameRuler:checkForStalledUnits()", 1800)
    assertTrue(stalled:find("local noRemainingUnitActions = activeUnits == 0 and totalUnits > 0", 1, true) ~= nil, "stalled-unit detection must handle turns with no unacted units left")
    assertTrue(stalled:find("noRemainingUnitActions or allRemainingUnitsStalled", 1, true) ~= nil, "no remaining unit actions should force turn completion when deployment is unavailable")
end)

runTest("scenario_red_policy_stages_visible_action_preview", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("scenarioRedPendingCommand", 1, true) ~= nil, "Scenario Red Policy should stage commands before execution")
    assertTrue(content:find("onlineAutoAdvanceState.showScenarioRedPolicyCommandPreview = function(command)", 1, true) ~= nil, "Scenario Red Policy preview helper missing")
    assertTrue(content:find("gameRuler:previewUnitMovement", 1, true) ~= nil, "Scenario Red Policy should reuse movement previews")
    assertTrue(content:find("gameRuler:previewUnitAttack", 1, true) ~= nil, "Scenario Red Policy should reuse attack previews")
    assertTrue(content:find("grid:addAIDecisionEffect", 1, true) ~= nil, "Scenario Red Policy should show target pointer feedback")
    assertTrue(content:find("grid:_cacheForcedPreviewCells()", 1, true) ~= nil, "Scenario Red Policy preview cells should be cache-visible immediately")
    assertTrue(content:find("onlineAutoAdvanceState.processPendingScenarioRedPolicyCommand = function", 1, true) ~= nil, "Scenario Red Policy pending executor missing")
    assertTrue(content:find("onlineAutoAdvanceState.stageScenarioRedPolicyCommand(command, policyRecord, redPolicyKey, stateKey, now)", 1, true) ~= nil, "Scenario Red Policy should stage chosen commands")
end)

runTest("scenario_commandant_ui_does_not_enqueue_duplicate_advances", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")

    local helper = localBlock(content, "if self.gameRuler.commandHubDefenseComplete then", 700)
    assertTrue(helper:find("local scenarioMode = self.gameRuler.isScenarioMode and self.gameRuler:isScenarioMode()", 1, true) ~= nil, "Scenario Mode commandant UI guard missing")
    assertTrue(helper:find("if not scenarioMode then", 1, true) ~= nil, "Scenario Mode should not schedule duplicate commandant auto-advance from UI")
    assertTrue(helper:find("self.gameRuler:scheduleAction(0.1", 1, true) ~= nil, "non-scenario commandant auto-advance should remain available")
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
        print("[PASS] " .. result.name)
    else
        print("[FAIL] " .. result.name .. ": " .. tostring(result.err))
    end
end

print(string.format("scenario_turn_handoff_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
