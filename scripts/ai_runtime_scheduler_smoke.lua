package.path = package.path .. ";./?.lua;./?/init.lua"

local passed = 0
local failed = 0

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s expected=%s actual=%s", message or "assertEquals", tostring(expected), tostring(actual)), 2)
    end
end

local function assertTrue(value, message)
    if not value then
        error(message or "expected true", 2)
    end
end

local function runTest(name, fn)
    io.write(string.format("[ai_runtime_scheduler_smoke] %s ... ", name))
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok")
    else
        failed = failed + 1
        print("FAIL")
        print(err)
    end
end

_G.GAME = {
    MODE = {
        AI_VS_AI = "aiVsAi",
        SINGLE_PLAYER = "singlePlayer",
        SCENARIO = "scenario"
    },
    CURRENT = {
        TURN = 1,
        MODE = "singlePlayer"
    }
}

local function valueOr(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

local function makeAi()
    local aiClass = {}
    aiClass.__index = aiClass

    require("ai_decision.turn_state").mixin(aiClass, {
        DEFAULT_SCORE_PARAMS = {TURN_FLOW = {START_DELAY = 0}},
        DEFAULT_AI_PARAMS = {},
        DEFAULT_UNIT_PROFILES = {},
        RUNTIME_DEFAULTS = {},
        ZERO = 0,
        ONE = 1,
        TWO = 2,
        THREE = 3,
        FOUR = 4,
        FIVE = 5,
        SIX = 6,
        SEVEN = 7,
        EIGHT = 8,
        TEN = 10,
        NEGATIVE_MIN_HP = -9999,
        NEGATIVE_ONE = -1,
        BASE_AI_REFERENCE = "base",
        RULE_CONTRACT = {},
        SETUP_RULE_CONTRACT = {},
        ACTION_RULE_CONTRACT = {},
        TURN_RULE_CONTRACT = {},
        PERFORMANCE_RULE_CONTRACT = {},
        DEFAULT_POSITIONAL_COMPONENT_WEIGHTS = {},
        STRATEGY_INTENT = {},
        STRATEGY_ROLE_ORDER = {},
        valueOr = valueOr,
        deepCopyValue = function(v) return v end,
        getMonotonicTimeSeconds = function() return 0 end,
        deepMerge = function(a) return a end,
        hashPosition = function() return "x" end,
        buildMovePatternKey = function() return "x" end,
        unitsInfo = {},
        aiInfluence = {},
        randomGen = {},
        aiConfig = {}
    })

    local phaseInfo = {
        currentPlayer = 1,
        currentPhase = "setup",
        turnPhaseName = "actions"
    }

    local gameRuler = {
        animating = false,
        scheduledActions = {},
        hasActiveAnimations = function(self)
            return self.animating == true
        end,
        scheduleAction = function(self, delay, callback)
            self.scheduledActions[#self.scheduledActions + 1] = {
                delay = delay,
                timeRemaining = delay,
                callback = callback
            }
        end,
        getCurrentPhaseInfo = function()
            return phaseInfo
        end
    }

    local ai = setmetatable({
        factionId = 1,
        gameRuler = gameRuler,
        neutralPlacements = 0
    }, aiClass)

    function ai:getTurnFlowScoreConfig()
        return {START_DELAY = 0}
    end

    function ai:handleAINeutralBuildingPlacement()
        self.neutralPlacements = self.neutralPlacements + 1
    end

    return ai, gameRuler, phaseInfo
end

local function runNextScheduled(gameRuler)
    local action = table.remove(gameRuler.scheduledActions, 1)
    assertTrue(action and action.callback, "expected scheduled callback")
    action.callback()
end

runTest("handle_ai_turn_schedules_only_one_pending_start", function()
    local ai, gameRuler, phaseInfo = makeAi()

    ai:handleAITurn(phaseInfo, {})
    ai:handleAITurn(phaseInfo, {})

    assertEquals(#gameRuler.scheduledActions, 1, "duplicate pending AI starts")
end)

runTest("scheduled_ai_start_rechecks_animations_before_processing", function()
    local ai, gameRuler, phaseInfo = makeAi()

    ai:handleAITurn(phaseInfo, {})
    gameRuler.animating = true
    gameRuler.scheduledActions[1].callback()

    assertEquals(ai.neutralPlacements, 0, "AI should not process while animations are active")
    assertEquals(ai._scheduledAITurnKey, nil, "pending key should clear after stale callback")
end)

runTest("scheduled_ai_start_ignores_stale_phase", function()
    local ai, gameRuler, phaseInfo = makeAi()

    ai:handleAITurn(phaseInfo, {})
    phaseInfo.currentPhase = "turn"
    gameRuler.scheduledActions[1].callback()

    assertEquals(ai.neutralPlacements, 0, "AI should not process a stale phase callback")
end)

runTest("scheduled_ai_start_runs_when_phase_and_animations_are_current", function()
    local ai, gameRuler, phaseInfo = makeAi()

    ai:handleAITurn(phaseInfo, {})
    gameRuler.scheduledActions[1].callback()

    assertEquals(ai.neutralPlacements, 1, "AI should process current setup phase")
    assertTrue(ai._scheduledAITurnKey == nil, "pending key should clear after execution")
end)

runTest("async_actions_decision_slices_without_executing_immediately", function()
    local ai, gameRuler, phaseInfo = makeAi()
    phaseInfo.currentPhase = "turn"
    phaseInfo.turnPhaseName = "actions"
    gameRuler.currentPlayer = 1

    ai.AI_PARAMS = {
        SCHEDULER = {
            AI_DECISION_ASYNC_ENABLED = true,
            AI_DECISION_SLICE_MS = 1,
            AI_DECISION_RESUME_DELAY = 0,
            AI_DECISION_MAX_WALL_MS = 5000,
            AI_DECISION_ASYNC_SOFT_BUDGET_MS = 900,
            AI_DECISION_ASYNC_HARD_BUDGET_MS = 1200
        }
    }
    ai.executedSequences = 0

    function ai:isTournamentAiEnabled()
        return true
    end

    function ai:getBestSequence(_, opts)
        assertTrue(opts and opts.cooperative == true, "async decision should request cooperative Tournament work")
        assertTrue(type(opts.budgetElapsedMs) == "function", "async decision should pass compute-time budget clock")
        assertTrue(type(opts.shouldYield) == "function", "async decision should pass yield hook")

        for _ = 1, 2 do
            local guardStart = os.clock()
            while not opts.shouldYield() do
                if (os.clock() - guardStart) > 0.05 then
                    error("yield hook did not open within guard time")
                end
            end
            coroutine.yield("ai_decision_slice")
        end

        return {{type = "skip"}}
    end

    function ai:executeActionsSequence(sequence)
        self.executedSequences = self.executedSequences + 1
        self.executedActionCount = #(sequence or {})
    end

    local phaseKey = table.concat({"1", "1", "turn", "actions", "1"}, ":")
    assertTrue(ai:startAsyncActionsDecision({}, phaseKey), "async decision should start")
    assertEquals(ai.executedSequences, 0, "async decision should not execute before scheduled resume")
    assertEquals(#gameRuler.scheduledActions, 1, "async decision should schedule first slice")

    runNextScheduled(gameRuler)
    assertEquals(ai.executedSequences, 0, "first slice should yield before execution")
    assertEquals(#gameRuler.scheduledActions, 1, "first yield should schedule continuation")

    runNextScheduled(gameRuler)
    assertEquals(ai.executedSequences, 0, "second slice should yield before execution")
    assertEquals(#gameRuler.scheduledActions, 1, "second yield should schedule continuation")

    runNextScheduled(gameRuler)
    assertEquals(ai.executedSequences, 1, "final slice should execute sequence")
    assertEquals(ai.executedActionCount, 1, "async sequence should preserve returned actions")
    assertTrue(ai._aiDecisionJob == nil, "async job should clear after completion")
end)

if failed > 0 then
    error(string.format("ai_runtime_scheduler_smoke failed: %d/%d", failed, passed + failed))
end

print(string.format("[ai_runtime_scheduler_smoke] passed %d/%d", passed, passed + failed))
