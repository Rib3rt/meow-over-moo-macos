package.path = package.path .. ";./?.lua"

local DEBUG_ENABLED = (os.getenv("AI_DEBUG") == "1" or os.getenv("AI_DEBUG") == "true")
local SKIP_BENCHMARK = (os.getenv("AI_SKIP_BENCHMARK") == "1" or os.getenv("AI_SKIP_BENCHMARK") == "true")

local function ensureGlobals()
    _G.love = _G.love or {}
    love.timer = love.timer or {}
    love.timer.getTime = love.timer.getTime or os.clock
    love.audio = love.audio or {}
    love.audio.newSource = love.audio.newSource or function()
        local source = {}
        function source:clone() return self end
        function source:play() end
        function source:stop() end
        function source:seek() end
        function source:setVolume() end
        function source:setPitch() end
        return source
    end

    _G.SETTINGS = _G.SETTINGS or {
        AUDIO = {SFX = false, SFX_VOLUME = 0},
        DISPLAY = {WIDTH = 1280, HEIGHT = 720, SCALE = 1, OFFSETX = 0, OFFSETY = 0}
    }

    _G.DEBUG = _G.DEBUG or {AI = false}
    DEBUG.AI = DEBUG_ENABLED

    _G.GAME = _G.GAME or {}
    GAME.CONSTANTS = GAME.CONSTANTS or {}
    GAME.CONSTANTS.GRID_SIZE = GAME.CONSTANTS.GRID_SIZE or 8
    GAME.CONSTANTS.MAX_ACTIONS_PER_TURN = GAME.CONSTANTS.MAX_ACTIONS_PER_TURN or 2
    GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE = GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE or 10

    GAME.MODE = GAME.MODE or {
        AI_VS_AI = "ai_vs_ai",
        MULTYPLAYER_LOCAL = "multi_local",
        MULTYPLAYER_NET = "multi_net"
    }

    GAME.CURRENT = GAME.CURRENT or {}
    GAME.CURRENT.TURN = GAME.CURRENT.TURN or 12
    GAME.CURRENT.MODE = GAME.CURRENT.MODE or GAME.MODE.AI_VS_AI
    GAME.CURRENT.AI_PLAYER_NUMBER = GAME.CURRENT.AI_PLAYER_NUMBER or 1

    GAME.getAIFactionId = GAME.getAIFactionId or function()
        return 1
    end
    GAME.isFactionControlledByAI = GAME.isFactionControlledByAI or function()
        return true
    end
end

ensureGlobals()

local aiConfig = require("ai_config")
local AI = require("ai")
local gameRuler = require("gameRuler")
local aiInfluence = require("ai_influence")
local RULE_CONTRACT = ((aiConfig.AI_PARAMS or {}).RULE_CONTRACT or {})
local DRAW_RULES = RULE_CONTRACT.DRAW or {}
local DRAW_LIMIT = DRAW_RULES.NO_INTERACTION_LIMIT or GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE or 10
local DRAW_URGENCY_ACTIVE_STREAK = math.max(1, DRAW_LIMIT - 1)
local DRAW_URGENCY_CRITICAL_STREAK = math.max(1, DRAW_LIMIT - 1)

aiInfluence.CONFIG.DEBUG_ENABLED = false

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s (expected=%s actual=%s)", message or "assertEquals failed", tostring(expected), tostring(actual)), 2)
    end
end

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for k, v in pairs(value) do
        copy[k] = deepCopy(v)
    end
    return copy
end

local function readAll(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function mkAI()
    local ai = AI.new({factionId = 1})
    ai.grid = {
        getUnitAt = function()
            return nil
        end
    }
    return ai
end

local function baseState()
    return {
        phase = "actions",
        turnNumber = 12,
        currentTurn = 12,
        currentPlayer = 1,
        turnsWithoutDamage = 0,
        hasDeployedThisTurn = true,
        turnActionCount = 0,
        firstActionRangedAttack = nil,
        units = {},
        unitsWithRemainingActions = {},
        commandHubs = {
            [1] = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
            [2] = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12}
        },
        neutralBuildings = {},
        supply = {[1] = {}, [2] = {}},
        attackedObjectivesThisTurn = {},
        guardAssignments = {}
    }
end

local results = {}
local benchmarkResult = nil

local function runTest(name, fn)
    local startedAt = os.clock()
    local ok, err = xpcall(fn, debug.traceback)
    local elapsedMs = (os.clock() - startedAt) * 1000
    results[#results + 1] = {
        name = name,
        ok = ok,
        err = err,
        ms = elapsedMs
    }
end

runTest("mandatory_fallback_has_legal_non_skip_action", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 3, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local legalActions = ai:collectLegalActions(state, {includeDeploy = false})
    assertTrue(#legalActions > 0, "expected at least one legal action")

    local fallback = ai:getMandatoryFallbackCandidates(state, {includeDeploy = false})
    assertTrue(#fallback > 0, "expected mandatory fallback candidates")
    for _, candidate in ipairs(fallback) do
        assertTrue(candidate.type ~= "skip", "skip candidate found while legal actions exist")
    end
end)

runTest("healer_full_hp_repair_exception_only_in_exception_path", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Healer", player = 1, row = 2, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 1, row = 2, col = 3, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local noException = ai:collectLegalActions(state, {
        includeMove = false,
        includeAttack = false,
        includeRepair = true,
        includeDeploy = false,
        allowFullHpHealerRepairException = false
    })
    assertEquals(#noException, 0, "unexpected full-HP repair action without exception")

    local withException = ai:collectLegalActions(state, {
        includeMove = false,
        includeAttack = false,
        includeRepair = true,
        includeDeploy = false,
        allowFullHpHealerRepairException = true
    })
    assertTrue(#withException > 0, "expected repair action via full-HP exception")
    assertEquals(withException[1].mandatoryException, "healer_full_hp_repair", "missing healer mandatory exception marker")
end)

runTest("deployment_offered_when_legal_and_blocked_after_deploy", function()
    local ai = mkAI()
    local state = baseState()
    state.hasDeployedThisTurn = false
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 4, col = 4, currentHp = 12, startingHp = 12}
    state.supply[1] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }

    local deploys = ai:getPossibleSupplyDeployments(state, true)
    assertTrue(#deploys > 0, "expected available deployments")

    local legal = ai:collectLegalActions(state, {
        includeMove = false,
        includeAttack = false,
        includeRepair = false,
        includeDeploy = true
    })
    local hasDeploy = false
    for _, entry in ipairs(legal) do
        if entry.type == "supply_deploy" then
            hasDeploy = true
            break
        end
    end
    assertTrue(hasDeploy, "expected supply_deploy in legal actions")

    state.hasDeployedThisTurn = true
    assertEquals(#ai:getPossibleSupplyDeployments(state, true), 0, "deployments should be blocked after deploy")
    local legalAfterDeploy = ai:collectLegalActions(state, {
        includeMove = false,
        includeAttack = false,
        includeRepair = false,
        includeDeploy = true
    })
    assertEquals(#legalAfterDeploy, 0, "legal deploy actions should be blocked after deploy")
end)

runTest("draw_counter_player_turn_increment_and_reset", function()
    local gr = setmetatable({
        currentTurn = 9,
        turnsWithoutDamage = 0,
        turnHadInteraction = false
    }, gameRuler)

    assertEquals(gr:incrementNoInteractionCounterPerPlayerTurn(), 0, "counter should not increment before draw start turn")

    gr.currentTurn = 10
    gr.turnHadInteraction = false
    assertEquals(gr:incrementNoInteractionCounterPerPlayerTurn(), 1, "counter should increment per player turn with no interaction")

    gr.turnHadInteraction = true
    assertEquals(gr:incrementNoInteractionCounterPerPlayerTurn(), 0, "counter should reset when interaction happened")

    gr.turnsWithoutDamage = 4
    gr.turnHadInteraction = false
    gr:resetNoInteractionCounter("unit_attack")
    assertEquals(gr.turnsWithoutDamage, 0, "resetNoInteractionCounter should reset counter to zero")
    assertTrue(gr.turnHadInteraction, "resetNoInteractionCounter should mark interaction")
end)

runTest("commandant_defense_attack_resets_draw_counter", function()
    local hubUnit = {
        name = "Commandant",
        shortName = "CM",
        player = 1,
        row = 4,
        col = 4,
        currentHp = 12,
        startingHp = 12
    }
    local enemyUnit = {
        name = "Wingstalker",
        shortName = "WS",
        player = 2,
        row = 4,
        col = 5,
        currentHp = 3,
        startingHp = 3,
        playerColor = {1, 0, 0}
    }

    local units = {
        ["4,4"] = hubUnit,
        ["4,5"] = enemyUnit
    }

    local grid = {
        movingUnits = {},
        isValidPosition = function(_, row, col)
            return row >= 1 and row <= 8 and col >= 1 and col <= 8
        end,
        getUnitAt = function(_, row, col)
            return units[row .. "," .. col]
        end,
        createCommandHubScanEffect = function() end,
        flashCell = function() end,
        createTeslaStrike = function() end,
        createDestructionEffect = function() end,
        addFloatingText = function() end,
        removeUnit = function(_, row, col)
            units[row .. "," .. col] = nil
        end,
        applyDamageFlash = function() end
    }

    local gr = setmetatable({
        currentPlayer = 1,
        currentGrid = grid,
        commandHubPositions = {
            [1] = {row = 4, col = 4},
            [2] = {row = 8, col = 8}
        },
        gameStats = {
            players = {
                [1] = {damageDealt = 0, damageTaken = 0, unitsDestroyed = 0, unitsLost = 0},
                [2] = {damageDealt = 0, damageTaken = 0, unitsDestroyed = 0, unitsLost = 0}
            },
            unitStats = {
                Commandant = {damageDealt = 0}
            }
        }
    }, gameRuler)

    function gr:scheduleAction(_, callback)
        callback()
    end
    function gr:findPlayerCommandHub(playerNum)
        return self.commandHubPositions[playerNum]
    end
    function gr:addLogEntry() end
    function gr:gridToChessNotation()
        return "E4"
    end
    function gr:calculateDamage()
        return 1
    end
    function gr:playerHasUnitsLeft()
        return true
    end
    function gr:getOpponentPlayer()
        return 2
    end
    function gr:setPhase() end
    function gr:nextTurnPhase()
        self._nextTurnPhaseCalled = true
        return true
    end
    function gr:resetNoInteractionCounter(reason)
        self._lastResetReason = reason
        self.turnsWithoutDamage = 0
        self.turnHadInteraction = true
        return 0
    end

    gr:executeCommandHubDefenseInternal()
    assertEquals(gr._lastResetReason, "commandant_attack", "commandant attack should reset draw counter")
end)

runTest("turn_phase_order_commandhub_to_actions", function()
    local gr = setmetatable({
        currentPhase = "turn",
        currentTurnPhase = "commandHub",
        drawGame = false,
        noMoreUnitsGameOver = false
    }, gameRuler)

    function gr:setPhase(phaseName, turnPhaseName)
        self._phaseTransition = {phaseName, turnPhaseName}
        self.currentPhase = phaseName
        self.currentTurnPhase = turnPhaseName
    end

    local transitioned = gr:nextTurnPhase()
    assertTrue(transitioned, "expected turn phase transition")
    assertEquals(gr._phaseTransition[1], "turn", "phase should remain TURN")
    assertEquals(gr._phaseTransition[2], "actions", "turn phase should transition commandHub -> actions")
end)

runTest("kill_and_move_kill_candidate_paths", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Crusher", player = 1, row = 3, col = 3, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Crusher", player = 1, row = 5, col = 5, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 3, col = 4, currentHp = 1, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 5, col = 7, currentHp = 1, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local directKills = ai:findKillShotsNoGate(state, {})
    assertTrue(#directKills > 0, "expected direct kill candidates")
    assertEquals(directKills[1].action.type, "attack", "direct kill candidate should be attack")

    local moveKills = ai:findMoveKillShotsNoGate(state, {})
    assertTrue(#moveKills > 0, "expected move+kill candidates")
    assertTrue(moveKills[1].moveAction ~= nil and moveKills[1].attackAction ~= nil, "move+kill candidate should include moveAction + attackAction")
end)

runTest("blocking_objectives_candidate_is_stable", function()
    local ai = mkAI()
    local state = baseState()
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 4, currentHp = 12, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 8, col = 4, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Wingstalker", player = 1, row = 3, col = 3, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 1, row = 2, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 3, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local first = ai:findBlockingEnemyObjectives(state, {})
    assertTrue(first ~= nil and first.action ~= nil, "expected blocking objective candidate")
    assertTrue((first.blockingValue or 0) > 0, "blocking objective candidate should have positive score")

    local second = ai:findBlockingEnemyObjectives(state, {})
    assertTrue(second ~= nil and second.action ~= nil, "expected stable second blocking objective candidate")

    local firstKey = string.format("%d,%d->%d,%d", first.action.unit.row, first.action.unit.col, first.action.target.row, first.action.target.col)
    local secondKey = string.format("%d,%d->%d,%d", second.action.unit.row, second.action.unit.col, second.action.target.row, second.action.target.col)
    assertEquals(firstKey, secondKey, "blocking objective selection should be deterministic for same state")
end)

runTest("beneficial_no_damage_selection_is_stable", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 6, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 5, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local firstList = ai:findBeneficialNoDamageMoves(state, {})
    assertTrue(#firstList > 0, "expected beneficial no-damage candidates")
    local secondList = ai:findBeneficialNoDamageMoves(state, {})
    assertTrue(#secondList > 0, "expected stable beneficial no-damage candidates")

    local first = firstList[1]
    local second = secondList[1]
    local firstKey = string.format("%d,%d->%d,%d", first.action.unit.row, first.action.unit.col, first.action.target.row, first.action.target.col)
    local secondKey = string.format("%d,%d->%d,%d", second.action.unit.row, second.action.unit.col, second.action.target.row, second.action.target.col)
    assertEquals(firstKey, secondKey, "beneficial no-damage selection should be deterministic for same state")
end)

runTest("safe_evasion_selection_is_stable", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 1, startingHp = 3, hasActed = false, hasMoved = false}
    }
    ai.getValidMoveCells = function(_, _, row, col)
        if row == 2 and col == 2 then
            return {
                {row = 1, col = 2},
                {row = 2, col = 1}
            }
        end
        return {}
    end
    ai.simulateStateAfterMove = function(_, boardState, unit, moveCell)
        return boardState, {
            name = unit.name,
            player = unit.player,
            row = moveCell.row,
            col = moveCell.col,
            currentHp = unit.currentHp,
            startingHp = unit.startingHp
        }
    end
    ai.wouldUnitDieNextTurn = function(_, _, unit)
        return unit.row == 2 and unit.col == 2
    end
    ai.getMovePositionalDelta = function()
        return 0, 0, 0
    end
    ai.getUnitBaseValue = function()
        return 100
    end

    local firstList = ai:findSafeEvasionMoves(state, {})
    assertTrue(#firstList > 0, "expected safe evasion candidates")
    local secondList = ai:findSafeEvasionMoves(state, {})
    assertTrue(#secondList > 0, "expected stable safe evasion candidates")

    local first = firstList[1]
    local second = secondList[1]
    local firstKey = string.format("%d,%d->%d,%d", first.action.unit.row, first.action.unit.col, first.action.target.row, first.action.target.col)
    local secondKey = string.format("%d,%d->%d,%d", second.action.unit.row, second.action.unit.col, second.action.target.row, second.action.target.col)
    assertEquals(firstKey, secondKey, "safe evasion selection should be deterministic for same state")
end)

runTest("pinned_ranged_unit_generates_escape_evasion_even_when_not_lethal_next_turn", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Cloudstriker", player = 1, row = 4, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 4, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    ai.getValidMoveCells = function(_, _, row, col)
        if row == 4 and col == 4 then
            return {
                {row = 3, col = 4},
                {row = 4, col = 2}
            }
        end
        return {}
    end

    local evasionMoves = ai:findSafeEvasionMoves(state, {})
    assertTrue(#evasionMoves > 0, "pinned cloudstriker should generate an escape move even if not lethal next turn")

    local top = evasionMoves[1]
    assertEquals(top.action.unit.row, 4, "expected cloudstriker source row")
    assertEquals(top.action.unit.col, 4, "expected cloudstriker source col")
    assertTrue(top.action.target.col ~= 4, "escape move should break same-column lock pressure")
end)

runTest("commandant_lane_blocker_not_evasion_moved_under_ranged_threat", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 4
    state.turnNumber = 4
    state.phase = "actions"
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 5, currentHp = 6, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 8, col = 5, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Artillery", player = 1, row = 2, col = 5, currentHp = 1, startingHp = 5, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Cloudstriker", player = 1, row = 1, col = 6, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Cloudstriker", player = 2, row = 4, col = 5, currentHp = 3, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Bastion", player = 2, row = 6, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false, actionsUsed = 0}
    }

    local sequence = ai:getBestSequence(state)
    assertTrue(#sequence > 0, "expected at least one action in sequence")

    for _, action in ipairs(sequence) do
        if action.type == "move"
            and action.unit
            and action.target
            and action.unit.row == 2
            and action.unit.col == 5 then
            local movedAwayFromShield = (action.target.row == 2 and action.target.col == 4)
            assertTrue(not movedAwayFromShield, "lane blocker moved away while commandant was under ranged LoS threat")
        end
    end
end)

runTest("commandant_under_attack_prefers_two_action_counter_combo", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 6
    state.turnNumber = 6
    state.phase = "actions"
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 7, col = 6, currentHp = 9, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 1, col = 5, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Wingstalker", player = 1, row = 6, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Cloudstriker", player = 2, row = 4, col = 6, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0}
    }

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = true,
            type = "ranged",
            threatLevel = 160,
            meleeThreats = 0,
            rangedThreats = 1,
            threats = {
                {
                    unit = {name = "Cloudstriker", player = 2, row = 4, col = 6},
                    distance = 3,
                    threatLevel = 160
                }
            }
        }
    end

    ai.findCommandantThreatMoveAttack = function()
        return {
            unit = state.units[1],
            moveAction = {
                type = "move",
                unit = {row = 6, col = 5},
                target = {row = 4, col = 5}
            },
            attackAction = {
                type = "attack",
                unit = {row = 4, col = 5},
                target = {row = 4, col = 6}
            },
            value = 999
        }
    end

    ai.findCommandantThreatDirectAttack = function()
        return nil
    end
    ai.findThreatCounterAttackMove = function()
        return nil
    end
    ai.findCommandantGuardMove = function()
        return {
            unit = state.units[1],
            action = {
                type = "move",
                unit = {row = 6, col = 5},
                target = {row = 6, col = 6}
            },
            value = 100
        }
    end
    ai.findCommandantDefenseUnblockMove = function()
        return nil
    end
    ai.findEmergencyDefensiveSupply = function()
        return nil
    end

    local sequence = ai:getBestSequence(state)
    assertEquals(#sequence, 2, "expected two-action defensive response sequence")
    assertEquals(sequence[1].type, "move", "expected first action to be move in response combo")
    assertEquals(sequence[1].unit.row, 6, "expected combo move from Wingstalker source row")
    assertEquals(sequence[1].unit.col, 5, "expected combo move from Wingstalker source col")
    assertEquals(sequence[1].target.row, 4, "expected combo move to projected counter row")
    assertEquals(sequence[1].target.col, 5, "expected combo move to projected counter col")
    assertEquals(sequence[2].type, "attack", "expected second action to be attack in response combo")
    assertEquals(sequence[2].target.row, 4, "expected combo attack against ranged threat row")
    assertEquals(sequence[2].target.col, 6, "expected combo attack against ranged threat col")
end)

runTest("commandant_threat_chains_direct_attacks_before_guard", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 6
    state.turnNumber = 6
    state.phase = "actions"
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 7, col = 6, currentHp = 8, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 1, col = 5, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Wingstalker", player = 1, row = 4, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Crusher", player = 1, row = 5, col = 6, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Cloudstriker", player = 2, row = 4, col = 6, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Wingstalker", player = 2, row = 1, col = 1, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0}
    }

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = true,
            type = "ranged",
            threatLevel = 180,
            meleeThreats = 0,
            rangedThreats = 1,
            threats = {
                {
                    unit = {name = "Cloudstriker", player = 2, row = 4, col = 6},
                    distance = 3,
                    threatLevel = 180
                }
            }
        }
    end

    ai.findCommandantThreatMoveAttack = function()
        return nil
    end

    local directCalls = 0
    ai.findCommandantThreatDirectAttack = function()
        directCalls = directCalls + 1
        if directCalls == 1 then
            return {
                unit = state.units[1],
                action = {
                    type = "attack",
                    unit = {row = 4, col = 5},
                    target = {row = 4, col = 6}
                },
                value = 900
            }
        elseif directCalls == 2 then
            return {
                unit = state.units[2],
                action = {
                    type = "attack",
                    unit = {row = 5, col = 6},
                    target = {row = 4, col = 6}
                },
                value = 800
            }
        end
        return nil
    end

    ai.findCommandantGuardMove = function()
        return {
            unit = state.units[1],
            action = {
                type = "move",
                unit = {row = 4, col = 5},
                target = {row = 5, col = 5}
            },
            value = 100
        }
    end

    ai.findCommandantDefenseUnblockMove = function()
        return nil
    end
    ai.findEmergencyDefensiveSupply = function()
        return nil
    end
    ai.findThreatCounterAttackMove = function()
        return nil
    end

    local sequence = ai:getBestSequence(state)
    assertEquals(#sequence, 2, "expected two-action severe threat response")
    assertEquals(sequence[1].type, "attack", "expected first chained action to be direct attack")
    assertEquals(sequence[2].type, "attack", "expected second chained action to be direct attack")
end)

runTest("commandant_threat_uses_emergency_supply_before_counter_move", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 7
    state.turnNumber = 7
    state.phase = "actions"
    state.hasDeployedThisTurn = false
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 7, col = 6, currentHp = 3, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 1, col = 5, currentHp = 12, startingHp = 12}
    state.supply[1] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }
    state.units = {
        {name = "Cloudstriker", player = 1, row = 5, col = 4, currentHp = 3, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Cloudstriker", player = 2, row = 5, col = 6, currentHp = 2, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0}
    }

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = true,
            type = "ranged",
            threatLevel = 260,
            meleeThreats = 0,
            rangedThreats = 1,
            threats = {
                {
                    unit = {name = "Cloudstriker", player = 2, row = 5, col = 6},
                    distance = 2,
                    threatLevel = 260
                }
            }
        }
    end

    ai.findCommandantThreatMoveAttack = function()
        return nil
    end

    ai.findCommandantThreatDirectAttack = function()
        return {
            unit = state.units[1],
            action = {
                type = "attack",
                unit = {row = 5, col = 4},
                target = {row = 5, col = 6}
            },
            value = 500
        }
    end

    ai.findCommandantGuardMove = function()
        return nil
    end

    ai.findCommandantDefenseUnblockMove = function()
        return nil
    end

    ai.findEmergencyDefensiveSupply = function()
        return {
            type = "supply_deploy",
            unitIndex = 1,
            unitName = "Wingstalker",
            target = {row = 6, col = 6},
            hub = {row = 7, col = 6},
            score = 900
        }
    end

    ai.findThreatCounterAttackMove = function()
        return {
            unit = state.units[1],
            action = {
                type = "move",
                unit = {row = 5, col = 4},
                target = {row = 6, col = 4}
            },
            value = 100
        }
    end

    local sequence = ai:getBestSequence(state)
    assertEquals(#sequence, 2, "expected two actions in severe commandant threat response")
    assertEquals(sequence[1].type, "attack", "expected first action to be direct threat attack")
    assertEquals(sequence[2].type, "supply_deploy", "expected emergency supply before counter move")
end)

runTest("draw_urgency_critical_prefers_neutral_attack_fallback", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 12
    state.turnNumber = 12
    state.turnsWithoutDamage = DRAW_URGENCY_CRITICAL_STREAK
    state.units = {
        {name = "Artillery", player = 1, row = 2, col = 2, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false, actionsUsed = 0}
    }
    state.neutralBuildings = {
        {row = 2, col = 4, currentHp = 5, startingHp = 5}
    }

    ai.getValidAttackCells = function(_, _, row, col)
        if row == 2 and col == 2 then
            return {{row = 2, col = 4}}
        end
        return {}
    end

    ai:updateDrawUrgencyState(state)
    assertTrue(ai:isDrawUrgencyCritical(), "expected critical draw urgency state")

    local sequence = {
        {type = "skip", unit = {row = 1, col = 1}},
        {type = "skip", unit = {row = 1, col = 1}}
    }

    local adjusted, replaced = ai:enforceDrawUrgencyAttackFallback(state, sequence, 2)
    assertTrue(replaced, "expected draw urgency fallback replacement")
    assertEquals(#adjusted, 2, "expected adjusted sequence length to remain at two actions")

    local foundAttack = false
    for _, action in ipairs(adjusted) do
        if action and action.type == "attack" then
            foundAttack = true
            assertEquals(action.target.row, 2, "expected neutral attack fallback target row")
            assertEquals(action.target.col, 4, "expected neutral attack fallback target col")
        end
    end
    assertTrue(foundAttack, "expected critical draw urgency to inject an attack action")
end)

runTest("stalemate_pressure_enforces_attack_fallback_before_draw_urgency", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 12
    state.turnNumber = 12
    state.turnsWithoutDamage = 1
    state.units = {
        {name = "Artillery", player = 1, row = 2, col = 2, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    ai:updateDrawUrgencyState(state)
    assertTrue(not ai:isDrawUrgencyActive(), "draw urgency should be inactive at low no-damage streak")
    assertTrue(ai:isStalematePressureActive(state), "stalemate pressure should be active")

    local sequence = {
        {type = "skip", unit = {row = 1, col = 1}},
        {type = "skip", unit = {row = 1, col = 1}}
    }

    local adjusted, replaced = ai:enforceDrawUrgencyAttackFallback(state, sequence, 2)
    assertTrue(replaced, "stalemate pressure should still enforce attack fallback")
    assertEquals(#adjusted, 2, "expected adjusted sequence length to remain at two actions")
    local foundAttack = false
    for _, action in ipairs(adjusted) do
        if action and action.type == "attack" then
            foundAttack = true
            assertEquals(action.target.row, 2, "expected attack target row")
            assertEquals(action.target.col, 4, "expected attack target col")
        end
    end
    assertTrue(foundAttack, "expected enforced fallback to inject an attack action")
end)

runTest("low_impact_pattern_penalty_increases_on_repeated_oscillation", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 15
    state.turnNumber = 15
    state.turnsWithoutDamage = 0

    local unit = {name = "Cloudstriker", player = 1, row = 3, col = 3, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    state.units = {
        unit,
        {name = "Crusher", player = 2, row = 8, col = 8, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local forwardKey = "1:Cloudstriker:3,3>3,4"
    local reverseKey = "1:Cloudstriker:3,4>3,3"
    ai.lowImpactMoveHistory = {
        [forwardKey] = {count = 2, lastTurn = 15},
        [reverseKey] = {count = 1, lastTurn = 15}
    }

    local penalty = ai:getLowImpactMovePenalty(state, unit, {row = 3, col = 4}, 1)
    assertTrue(penalty > 0, "expected repeated low-impact loop penalty to be positive")
end)

runTest("doomed_unit_lethal_attack_selected_without_finisher_flags", function()
    local ai = mkAI()
    local state = baseState()
    local attacker = {name = "Cloudstriker", player = 1, row = 3, col = 3, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    local target = {name = "Wingstalker", player = 2, row = 3, col = 4, currentHp = 2, startingHp = 3, hasActed = false, hasMoved = false}
    state.units = {attacker, target}

    ai.wouldUnitDieNextTurn = function(_, _, unitRef)
        return unitRef == attacker
    end
    ai.getValidAttackCells = function(_, _, row, col)
        if row == 3 and col == 3 then
            return {{row = 3, col = 4}}
        end
        return {}
    end
    ai.isDoomedFinisherAttack = function()
        return false
    end

    local unitsInfo = require("unitsInfo")
    local originalCalc = unitsInfo.calculateAttackDamage
    unitsInfo.calculateAttackDamage = function()
        return 2, false
    end

    local ok, resultOrErr = pcall(function()
        return ai:findLastAttackForDoomedUnits(state, {}, {
            requireLethalOnly = true,
            includeFinishers = false
        })
    end)
    unitsInfo.calculateAttackDamage = originalCalc
    assertTrue(ok, resultOrErr)

    local candidate = resultOrErr
    assertTrue(candidate ~= nil, "expected doomed lethal attack candidate")
    assertEquals(candidate.action.type, "attack", "expected direct doomed lethal attack")
    assertEquals(candidate.action.target.row, 3, "expected doomed lethal target row")
    assertEquals(candidate.action.target.col, 4, "expected doomed lethal target col")
end)

runTest("beneficial_moves_selection_is_stable", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 6, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 5, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local firstList = ai:findBeneficialMoves(state, {})
    assertTrue(#firstList > 0, "expected beneficial move candidates")
    local secondList = ai:findBeneficialMoves(state, {})
    assertTrue(#secondList > 0, "expected stable beneficial move candidates")

    local first = firstList[1]
    local second = secondList[1]
    local firstKey = string.format("%d,%d->%d,%d", first.action.unit.row, first.action.unit.col, first.action.target.row, first.action.target.col)
    local secondKey = string.format("%d,%d->%d,%d", second.action.unit.row, second.action.unit.col, second.action.target.row, second.action.target.col)
    assertEquals(firstKey, secondKey, "beneficial move selection should be deterministic for same state")
end)

runTest("risky_move_selection_is_stable", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }
    ai.getValidMoveCells = function(_, _, row, col)
        if row == 2 and col == 2 then
            return {
                {row = 1, col = 2},
                {row = 2, col = 1}
            }
        end
        return {}
    end
    ai.isVulnerableMovePosition = function()
        return true
    end
    ai.evaluateRiskyMoveComponents = function()
        return {
            totalValue = 10,
            enemyHub = nil,
            currentDistToEnemyHub = nil,
            newDistToEnemyHub = nil,
            trapBonus = 0,
            reasonThreatBonus = 0
        }
    end
    ai.getRiskyMoveReason = function()
        return "test_reason"
    end

    local first = ai:findRiskyMoves(state, {})
    assertTrue(first ~= nil and first.action ~= nil, "expected risky move candidate")
    local second = ai:findRiskyMoves(state, {})
    assertTrue(second ~= nil and second.action ~= nil, "expected stable risky move candidate")

    local firstKey = string.format("%d,%d->%d,%d", first.action.unit.row, first.action.unit.col, first.action.target.row, first.action.target.col)
    local secondKey = string.format("%d,%d->%d,%d", second.action.unit.row, second.action.unit.col, second.action.target.row, second.action.target.col)
    assertEquals(firstKey, secondKey, "risky move selection should be deterministic for same state")
end)

runTest("risky_move_attack_safety_uses_projected_attacker_position", function()
    local ai = mkAI()
    local state = baseState()
    local attacker = {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    local target = {name = "Wingstalker", player = 2, row = 2, col = 4, currentHp = 2, startingHp = 3, hasActed = false, hasMoved = false}
    state.units = {attacker, target}

    ai.collectAttackTargetEntries = function(_, _, _, opts)
        if not opts or opts.mode ~= "move" then
            return {}
        end
        return {
            {
                unit = attacker,
                target = target,
                damage = 2,
                targetHp = 2,
                specialUsed = false,
                moveCell = {row = 2, col = 3},
                moveAction = {
                    type = "move",
                    unit = {row = 2, col = 2},
                    target = {row = 2, col = 3}
                },
                attackAction = {
                    type = "attack",
                    unit = {row = 2, col = 3},
                    target = {row = 2, col = 4}
                }
            }
        }
    end

    ai.isAttackSafe = function(_, _, attackerRef)
        return attackerRef and attackerRef.row == 2 and attackerRef.col == 3
    end

    local candidates = ai:collectRiskyAttackCandidates(state, {}, {
        moveThenAttack = true,
        requireSafeMove = false,
        requireSafeAttack = true,
        includeFriendlyFireCheck = false,
        useRiskDamageEligibility = false,
        minDamage = 1,
        rejectSpecial = false,
        rejectLeaveAtOneHp = false,
        scoreFn = function()
            return 10
        end
    })

    assertEquals(#candidates, 1, "projected move+attack safety gate should accept candidate when projected attacker is safe")
end)

runTest("risky_move_attack_attacker_will_die_flag_uses_projected_position", function()
    local ai = mkAI()
    local state = baseState()
    local attacker = {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    local target = {name = "Wingstalker", player = 2, row = 2, col = 4, currentHp = 2, startingHp = 3, hasActed = false, hasMoved = false}
    state.units = {attacker, target}

    ai.collectAttackTargetEntries = function(_, _, _, opts)
        if not opts or opts.mode ~= "move" then
            return {}
        end
        return {
            {
                unit = attacker,
                target = target,
                damage = 2,
                targetHp = 2,
                specialUsed = false,
                moveCell = {row = 2, col = 3},
                moveAction = {
                    type = "move",
                    unit = {row = 2, col = 2},
                    target = {row = 2, col = 3}
                },
                attackAction = {
                    type = "attack",
                    unit = {row = 2, col = 3},
                    target = {row = 2, col = 4}
                }
            }
        }
    end

    ai.isAttackSafe = function(_, _, attackerRef)
        if attackerRef and attackerRef.row == 2 and attackerRef.col == 3 then
            return false
        end
        return true
    end

    local candidates = ai:collectRiskyAttackCandidates(state, {}, {
        moveThenAttack = true,
        requireSafeMove = false,
        requireSafeAttack = false,
        includeAttackerWillDie = true,
        includeFriendlyFireCheck = false,
        useRiskDamageEligibility = false,
        minDamage = 1,
        rejectSpecial = false,
        rejectLeaveAtOneHp = false,
        scoreFn = function()
            return 10
        end
    })

    assertEquals(#candidates, 1, "expected one risky move+attack candidate")
    assertTrue(candidates[1].attackerWillDie == true, "attackerWillDie should use projected post-move attacker position")
end)

runTest("risky_move_evaluation_consistency", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 6, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Crusher", player = 2, row = 5, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    }

    local unit = state.units[1]
    local movePos = {row = 2, col = 3}

    local eval = ai:evaluateRiskyMoveComponents(state, unit, movePos, 1)
    assertTrue(type(eval.totalValue) == "number", "risky move evaluation must produce numeric total value")

    local valueDirect = ai:calculateRiskyMoveValue(state, unit, movePos)
    local valuePrecomputed = ai:calculateRiskyMoveValue(state, unit, movePos, eval)
    assertEquals(valueDirect, valuePrecomputed, "risky move value should match with precomputed evaluation")

    local reasonDirect = ai:getRiskyMoveReason(state, unit, movePos)
    local reasonPrecomputed = ai:getRiskyMoveReason(state, unit, movePos, eval)
    assertEquals(reasonDirect, reasonPrecomputed, "risky move reason should match with precomputed evaluation")
end)

runTest("threat_bonus_uses_projected_position", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local threatBonus = ai:calculateThreatBonus(state, state.units[1], {row = 2, col = 3})
    assertTrue(threatBonus > 0, "projected-position threat bonus should be positive when a target is attackable from projected tile")
end)

runTest("reachability_bonus_projected_targets_path", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local simState, movedUnit = ai:simulateStateAfterMove(state, state.units[1], {row = 2, col = 3})
    local bonus = ai:calculateNextTurnReachabilityBonus(simState, movedUnit, {row = 2, col = 3})
    assertTrue(type(bonus) == "number", "reachability bonus should be numeric")
    assertTrue(bonus > 0, "reachability bonus should be positive when move unlocks new projected target")
end)

runTest("positional_component_weights_are_canonical", function()
    local ai = mkAI()
    ai.AI_PARAMS = aiConfig.normalizeConfig({
        SCORES = {
            POSITIONAL = {
                COMPONENT_WEIGHTS = {
                    IMPROVEMENT = 1.7,
                    REPAIR = 1.2,
                    THREAT = 0.9,
                    OFFENSIVE = 0.6,
                    FORWARD_PRESSURE = 0.55
                }
            }
        },
        EVAL = {
            POSITIONAL = {
                COMPONENT_WEIGHTS = {
                    IMPROVEMENT = 9.0,
                    REPAIR = 9.0,
                    THREAT = 9.0,
                    OFFENSIVE = 9.0,
                    FORWARD_PRESSURE = 9.0
                }
            }
        }
    })
    ai._scoreConfig = nil

    local weights = ai:getPositionalComponentWeights()
    assertEquals(weights.improvement, 1.7, "expected canonical positional IMPROVEMENT weight")
    assertEquals(weights.repair, 1.2, "expected canonical positional REPAIR weight")
    assertEquals(weights.threat, 0.9, "expected canonical positional THREAT weight")
    assertEquals(weights.offensive, 0.6, "expected canonical positional OFFENSIVE weight")
    assertEquals(weights.forwardPressure, 0.55, "expected canonical positional FORWARD_PRESSURE weight")
    assertEquals(
        ai.AI_PARAMS.EVAL.POSITIONAL.COMPONENT_WEIGHTS.IMPROVEMENT,
        1.7,
        "expected legacy positional alias to mirror canonical values"
    )
end)

runTest("draw_urgency_runs_before_positioning_and_deploy", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 12
    state.turnNumber = 12
    state.turnsWithoutDamage = DRAW_URGENCY_ACTIVE_STREAK
    state.hasDeployedThisTurn = false
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 5, currentHp = 12, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 8, col = 5, currentHp = 12, startingHp = 12}
    state.supply[1] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 1, row = 3, col = 3, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 3, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    ai.findHighValueSafeAttacks = function()
        return {
            {
                unit = state.units[1],
                action = {
                    type = "attack",
                    unit = {row = 2, col = 2},
                    target = {row = 2, col = 3}
                },
                value = 500
            }
        }
    end
    ai.findBeneficialNoDamageMoves = function()
        return {
            {
                unit = state.units[2],
                action = {
                    type = "move",
                    unit = {row = 3, col = 3},
                    target = {row = 3, col = 4}
                },
                value = 400
            }
        }
    end
    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitIndex = 1,
            unitName = "Wingstalker",
            target = {row = 1, col = 6},
            hub = {row = 1, col = 5},
            score = 900
        }
    end
    ai.findBeneficialMoves = function()
        return {}
    end

    local sequence = ai:getBestSequence(state)
    assertTrue(#sequence > 0, "expected non-empty draw urgency sequence")
    assertEquals(sequence[1].type, "attack", "expected attack to be selected before passive positioning/deploy")
    for _, action in ipairs(sequence) do
        assertTrue(action.type ~= "supply_deploy", "draw urgency gate should suppress deploy when attack path exists")
        local isInjectedPassiveMove = action.type == "move"
            and action.unit
            and action.target
            and action.unit.row == 3
            and action.unit.col == 3
            and action.target.row == 3
            and action.target.col == 4
        assertTrue(not isInjectedPassiveMove, "draw urgency gate should suppress passive Priority14 move when attack path exists")
    end
end)

runTest("priority_1_to_9_auto_window_skips_planning_when_triggered", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 3, currentHp = 2, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local attacker = state.units[1]
    local target = state.units[2]

    ai.findSafeKillAttacks = function()
        return {
            {
                unit = attacker,
                action = {
                    type = "attack",
                    unit = {row = attacker.row, col = attacker.col},
                    target = {row = target.row, col = target.col}
                },
                value = 500
            }
        }
    end
    ai.findSafeMoveAttackKills = function() return {} end
    ai.findTwoUnitKillCombinations = function() return {} end
    ai.findCorvetteLineOfSightKills = function() return {} end
    ai.findNotSoSafeKillAttacks = function() return {} end
    ai.findNotSoSafeMoveAttackKills = function() return {} end
    ai.findEmergencyDefensiveSupply = function() return nil end
    ai.findThreatCounterAttackMove = function() return nil end
    ai.findSurvivalRepairs = function()
        error("Priority25 should be skipped when Priority01-09 auto window already produced actions")
    end
    ai.findSurvivalMoveRepairs = function()
        error("Priority26 should be skipped when Priority01-09 auto window already produced actions")
    end

    local sequence = ai:getBestSequence(state)
    assertTrue(#sequence > 0, "expected non-empty sequence")
    assertEquals(sequence[1].type, "attack", "expected Priority01 safe kill to lead the sequence")
end)

runTest("global_direct_attack_preference_beats_move_attack_combo", function()
    local ai = mkAI()
    local state = baseState()
    local cloud = {name = "Cloudstriker", player = 1, row = 2, col = 7, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    local bastion = {name = "Bastion", player = 1, row = 5, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    local target = {name = "Wingstalker", player = 2, row = 5, col = 7, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    state.units = {cloud, bastion, target}
    state.turnsWithoutDamage = 0

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = false,
            isUnderProjectedThreat = false,
            threatLevel = 0,
            projectedThreatLevel = 0,
            threats = {},
            threatsProjected = {}
        }
    end
    ai.updateStrategicPlanState = function(selfRef)
        selfRef.strategicPlanState = {
            active = false,
            intent = "STABILIZE",
            planId = nil,
            planScore = 0,
            planTurnsLeft = 0
        }
        return selfRef.strategicPlanState
    end

    ai.findSafeKillAttacks = function() return {} end
    ai.findSafeMoveAttackKills = function() return {} end
    ai.findTwoUnitKillCombinations = function() return {} end
    ai.findCorvetteLineOfSightKills = function() return {} end
    ai.findNotSoSafeKillAttacks = function() return {} end
    ai.findNotSoSafeMoveAttackKills = function() return {} end
    ai.findSurvivalRepairs = function() return nil end
    ai.findSurvivalMoveRepairs = function() return nil end
    ai.findHighValueSafeAttacks = function() return {} end
    ai.findHighValueAttacks = function() return {} end
    ai.findMoveAttackCombinations = function()
        return {
            {
                unit = bastion,
                moveAction = {
                    type = "move",
                    unit = {row = 5, col = 5},
                    target = {row = 5, col = 6}
                },
                attackAction = {
                    type = "attack",
                    unit = {row = 5, col = 6},
                    target = {row = 5, col = 7}
                },
                damage = 1,
                targetHp = 3,
                value = 600
            }
        }
    end

    local sequence = ai:getBestSequence(state)
    assertTrue(#sequence > 0, "expected sequence with direct-attack preference")
    assertEquals(sequence[1].type, "attack", "expected direct attack to replace move+attack combo")
    assertEquals(sequence[1].unit.row, 2, "expected Cloudstriker direct attack unit row")
    assertEquals(sequence[1].unit.col, 7, "expected Cloudstriker direct attack unit col")
    assertEquals(sequence[1].target.row, 5, "expected target row to match combo target")
    assertEquals(sequence[1].target.col, 7, "expected target col to match combo target")
end)

runTest("draw_urgency_does_not_override_hard_hub_defense", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 12
    state.turnNumber = 12
    state.turnsWithoutDamage = DRAW_URGENCY_ACTIVE_STREAK
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 7, col = 6, currentHp = 6, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 1, col = 5, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Wingstalker", player = 1, row = 5, col = 6, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Cloudstriker", player = 2, row = 4, col = 6, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0}
    }

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = true,
            isUnderProjectedThreat = true,
            type = "ranged",
            threatLevel = 220,
            immediateThreatLevel = 180,
            projectedThreatLevel = 40,
            meleeThreats = 0,
            rangedThreats = 1,
            lookaheadTurnsUsed = 3,
            threats = {
                {
                    unit = {name = "Cloudstriker", player = 2, row = 4, col = 6},
                    distance = 3,
                    threatLevel = 180
                }
            },
            threatsProjected = {}
        }
    end
    ai.findCommandantThreatMoveAttack = function()
        return nil
    end
    ai.findCommandantThreatDirectAttack = function()
        return {
            unit = state.units[1],
            action = {
                type = "attack",
                unit = {row = 5, col = 6},
                target = {row = 4, col = 6}
            },
            value = 800
        }
    end
    ai.findCommandantGuardMove = function()
        return {
            unit = state.units[1],
            action = {
                type = "move",
                unit = {row = 5, col = 6},
                target = {row = 6, col = 6}
            },
            value = 100
        }
    end
    ai.findThreatCounterAttackMove = function()
        return nil
    end
    ai.findCommandantDefenseUnblockMove = function()
        return nil
    end
    ai.findEmergencyDefensiveSupply = function()
        return nil
    end

    local sequence = ai:getBestSequence(state)
    assertTrue(#sequence > 0, "expected defensive sequence while draw urgency is active")
    assertEquals(sequence[1].type, "attack", "draw urgency must not override hard commandant defense attack")
    assertEquals(sequence[1].target.row, 4, "expected commandant defense target row")
    assertEquals(sequence[1].target.col, 6, "expected commandant defense target col")
end)

runTest("hub_threat_dynamic_horizon_detects_move_attack_in_3_turn_window", function()
    local ai = mkAI()
    local state = baseState()
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 5, currentHp = 6, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 8, col = 5, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Cloudstriker", player = 2, row = 8, col = 6, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    }

    ai.getUnitThreatTiming = function(_, _, _, _, maxTurns)
        if maxTurns >= 3 then
            return 3, "move_attack"
        end
        return nil, nil
    end

    local threat = ai:analyzeHubThreat(state)
    assertTrue(threat.isUnderProjectedThreat == true, "expected projected commandant threat from dynamic horizon")
    assertEquals(threat.lookaheadTurnsUsed, 3, "expected threatened lookahead horizon to expand to 3 turns")
    assertTrue((threat.projectedThreatLevel or 0) > 0, "expected positive projected threat level")
    assertTrue(#(threat.threatsProjected or {}) > 0, "expected projected threat entries")
    assertEquals(threat.threatsProjected[1].threatTurn, 3, "expected projected threat turn index")
    assertEquals(threat.threatsProjected[1].threatMode, "move_attack", "expected projected threat mode")
end)

runTest("commandant_response_prefers_threat_neutralization_over_guard_when_available", function()
    local ai = mkAI()
    local paramsCopy = aiConfig.normalizeConfig(deepCopy(aiConfig.AI_PARAMS))
    paramsCopy.SCORES = paramsCopy.SCORES or {}
    paramsCopy.SCORES.STRATEGY = paramsCopy.SCORES.STRATEGY or {}
    paramsCopy.SCORES.STRATEGY.VERIFIER = paramsCopy.SCORES.STRATEGY.VERIFIER or {}
    paramsCopy.SCORES.STRATEGY.VERIFIER.ENABLED = false
    ai.AI_PARAMS = paramsCopy
    ai._scoreConfig = nil

    local state = baseState()
    state.currentTurn = 7
    state.turnNumber = 7
    state.phase = "actions"
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 7, col = 6, currentHp = 9, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 1, col = 5, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Wingstalker", player = 1, row = 6, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0}
    }

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = false,
            isUnderProjectedThreat = true,
            type = "projected",
            threatLevel = 110,
            immediateThreatLevel = 20,
            projectedThreatLevel = 90,
            meleeThreats = 0,
            rangedThreats = 1,
            lookaheadTurnsUsed = 3,
            threats = {},
            threatsProjected = {
                {
                    unit = {name = "Cloudstriker", player = 2, row = 4, col = 6},
                    threatLevel = 90,
                    distance = 3,
                    threatTurn = 2,
                    threatMode = "move_attack"
                }
            }
        }
    end
    ai.findCommandantThreatMoveAttack = function()
        return nil
    end
    ai.findCommandantThreatDirectAttack = function()
        return nil
    end
    ai.findThreatCounterAttackMove = function()
        return {
            unit = state.units[1],
            action = {
                type = "move",
                unit = {row = 6, col = 5},
                target = {row = 5, col = 5}
            },
            value = 500
        }
    end
    ai.findCommandantGuardMove = function()
        return {
            unit = state.units[1],
            action = {
                type = "move",
                unit = {row = 6, col = 5},
                target = {row = 6, col = 6}
            },
            value = 100
        }
    end
    ai.findCommandantDefenseUnblockMove = function()
        return nil
    end
    ai.findEmergencyDefensiveSupply = function()
        return nil
    end

    local sequence = ai:getBestSequence(state)
    assertTrue(#sequence > 0, "expected defensive response sequence")
    assertEquals(sequence[1].type, "move", "expected counter neutralization move to be selected")
    assertEquals(sequence[1].target.row, 5, "expected counter move row to be preferred over guard move")
    assertEquals(sequence[1].target.col, 5, "expected counter move col to be preferred over guard move")
end)

runTest("post_defense_followup_prefers_counter_over_generic_positioning", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 4
    state.turnNumber = 4
    state.phase = "actions"
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 3, currentHp = 12, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 7, col = 2, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Artillery", player = 1, row = 4, col = 3, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Cloudstriker", player = 1, row = 1, col = 4, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
        {name = "Cloudstriker", player = 2, row = 4, col = 1, currentHp = 3, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0}
    }

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = true,
            isUnderProjectedThreat = true,
            type = "ranged",
            threatLevel = 170,
            immediateThreatLevel = 130,
            projectedThreatLevel = 40,
            meleeThreats = 0,
            rangedThreats = 1,
            lookaheadTurnsUsed = 3,
            threats = {
                {
                    unit = {name = "Cloudstriker", player = 2, row = 4, col = 1},
                    distance = 3,
                    threatLevel = 130
                }
            },
            threatsProjected = {}
        }
    end

    ai.findCommandantThreatMoveAttack = function()
        return nil
    end

    local directCalls = 0
    ai.findCommandantThreatDirectAttack = function()
        directCalls = directCalls + 1
        if directCalls == 1 then
            return {
                unit = state.units[1],
                action = {
                    type = "attack",
                    unit = {row = 4, col = 3},
                    target = {row = 4, col = 1}
                },
                value = 900
            }
        end
        return nil
    end

    ai.findThreatCounterAttackMove = function()
        return {
            unit = state.units[2],
            action = {
                type = "move",
                unit = {row = 1, col = 4},
                target = {row = 4, col = 4}
            },
            value = 500
        }
    end

    ai.findCommandantGuardMove = function()
        return {
            unit = state.units[2],
            action = {
                type = "move",
                unit = {row = 1, col = 4},
                target = {row = 2, col = 4}
            },
            value = 100
        }
    end

    ai.findBeneficialNoDamageMoves = function()
        return {
            {
                unit = state.units[2],
                action = {
                    type = "move",
                    unit = {row = 1, col = 4},
                    target = {row = 2, col = 4}
                },
                value = 999
            }
        }
    end

    ai.findCommandantDefenseUnblockMove = function()
        return nil
    end
    ai.findEmergencyDefensiveSupply = function()
        return nil
    end

    local sequence = ai:getBestSequence(state)
    assertEquals(#sequence, 2, "expected full two-action sequence")
    assertEquals(sequence[1].type, "attack", "expected commandant threat direct attack as first action")
    assertEquals(sequence[2].type, "move", "expected post-defense follow-up move as second action")
    assertEquals(sequence[2].target.row, 4, "expected counter follow-up row")
    assertEquals(sequence[2].target.col, 4, "expected counter follow-up col (not generic positioning move)")
end)

runTest("healer_not_primary_attacker_before_late_endgame", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 2
    state.turnNumber = 2
    state.units = {
        {name = "Healer", player = 1, row = 4, col = 4, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 4, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    assertTrue(ai:shouldHealerBeOffensive(state) == false, "healer should not be offensive in early game")
    local attacks = ai:findHighValueSafeAttacks(state, {})
    assertEquals(#attacks, 0, "healer should not be selected as primary attacker before late endgame")
end)

runTest("healer_offense_policy_strict_support_with_emergency_exception", function()
    local ai = mkAI()
    local lateState = baseState()
    lateState.currentTurn = 14
    lateState.turnNumber = 14
    lateState.units = {
        {name = "Healer", player = 1, row = 4, col = 4, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 4, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    assertTrue(ai:shouldHealerBeOffensive(lateState) == false, "strict support doctrine should keep healer non-offensive in late endgame")

    local emergencyState = baseState()
    emergencyState.currentTurn = 3
    emergencyState.turnNumber = 3
    emergencyState.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 5, currentHp = 4, startingHp = 12}
    emergencyState.units = {
        {name = "Healer", player = 1, row = 2, col = 5, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 2, row = 4, col = 5, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    }
    local emergencyThreat = {
        isUnderAttack = true,
        isUnderProjectedThreat = true,
        threatLevel = 180,
        projectedThreatLevel = 60
    }
    assertTrue(
        ai:shouldHealerBeOffensive(emergencyState, {
            allowEmergencyDefense = true,
            commandantThreatData = emergencyThreat
        }) == true,
        "healer offense should be allowed for emergency commandant defense when needed"
    )
end)

runTest("healer_orbit_move_does_not_overshoot_frontline", function()
    local ai = mkAI()
    local state = baseState()
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 7, col = 6, currentHp = 12, startingHp = 12}
    local healer = {name = "Healer", player = 1, row = 6, col = 6, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    state.units = {
        healer
    }

    assertTrue(
        ai:isHealerOrbitMoveAllowed(state, healer, {row = 5, col = 6}, 1) == true,
        "healer should be allowed to move from distance 1 to desired orbit"
    )
    assertTrue(
        ai:isHealerOrbitMoveAllowed(state, healer, {row = 3, col = 6}, 1) == false,
        "healer should not overshoot from hub-adjacent to far frontline orbit"
    )
end)

runTest("supply_deploy_rejects_spawn_that_is_threatened_before_impact", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 6
    state.turnNumber = 6
    state.currentPlayer = 1
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 7, col = 6, currentHp = 12, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 1, col = 4, currentHp = 12, startingHp = 12}
    state.supply[1] = {
        {name = "Artillery", currentHp = 5, startingHp = 5}
    }
    state.units = {
        {name = "Cloudstriker", player = 2, row = 4, col = 5, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 1, row = 6, col = 6, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 1, row = 8, col = 6, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 1, row = 7, col = 7, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local deployment = ai:findEnhancedSupplyDeployment(state, {})
    assertTrue(deployment == nil, "deployment should be skipped when spawn is threatened before first projected impact")
end)

runTest("supply_deploy_prefers_primary_threat_line_block_under_immediate_hub_threat", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 7
    state.turnNumber = 7
    state.currentPlayer = 1
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 4, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12}
    state.supply[1] = {
        {name = "Earthstalker", currentHp = 3, startingHp = 3}
    }

    local threatUnit = {
        name = "Cloudstriker",
        player = 2,
        row = 1,
        col = 4,
        currentHp = 4,
        startingHp = 4,
        hasActed = false,
        hasMoved = false
    }
    state.units = {threatUnit}

    ai.getPossibleSupplyDeployments = function()
        return {
            {
                type = "supply_deploy",
                unitIndex = 1,
                unitName = "Earthstalker",
                target = {row = 2, col = 2},
                hub = {row = 1, col = 2},
                score = 250
            },
            {
                type = "supply_deploy",
                unitIndex = 1,
                unitName = "Earthstalker",
                target = {row = 1, col = 3},
                hub = {row = 1, col = 2},
                score = 40
            }
        }
    end

    ai.wouldUnitDieNextTurn = function()
        return false
    end

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = true,
            isUnderProjectedThreat = false,
            type = "ranged",
            threatLevel = 320,
            immediateThreatLevel = 320,
            projectedThreatLevel = 0,
            meleeThreats = 0,
            rangedThreats = 1,
            threats = {
                {
                    unit = threatUnit,
                    distance = 2,
                    threatLevel = 320
                }
            },
            threatsProjected = {}
        }
    end

    ai.getUnitThreatTiming = function(_, attacker, target)
        if attacker and attacker.player == 2 and target and target.player == 1 and target.name == "Earthstalker" then
            return 2
        end

        if attacker and attacker.player == 1 and attacker.name == "Earthstalker" and target == threatUnit then
            if attacker.row == 1 and attacker.col == 3 then
                return 2
            end
            return nil
        end

        return nil
    end

    local deployment = ai:findEnhancedSupplyDeployment(state, {})
    assertTrue(deployment ~= nil, "expected a defensive deployment candidate")
    assertEquals(deployment.target.row, 1, "expected deployment to block primary threat line")
    assertEquals(deployment.target.col, 3, "expected deployment to block primary threat line")
end)

runTest("all_vs_defense_consumes_both_actions_when_hub_threat_active", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 9
    state.turnNumber = 9
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 7, col = 5, currentHp = 7, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 1, col = 5, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Wingstalker", player = 1, row = 6, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 2, row = 4, col = 5, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    }

    ai.buildDefenseActionBundle = function()
        return {
            {
                kind = "pair",
                priority = 999,
                unit = state.units[1],
                moveAction = {
                    type = "move",
                    unit = {row = 6, col = 5},
                    target = {row = 4, col = 5}
                },
                attackAction = {
                    type = "attack",
                    unit = {row = 4, col = 5},
                    target = {row = 4, col = 5}
                }
            }
        }
    end

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = true,
            isUnderProjectedThreat = true,
            threatLevel = 240,
            projectedThreatLevel = 70,
            threats = {},
            threatsProjected = {}
        }
    end

    local sequence = ai:getBestSequence(state)
    assertEquals(#sequence, 2, "defense bundle should consume both actions during hard threat")
    assertEquals(sequence[1].type, "move", "expected defense bundle move as first action")
    assertEquals(sequence[2].type, "attack", "expected defense bundle attack as second action")
end)

runTest("defense_bundle_prefers_neutralize_over_guard_only_if_available", function()
    local ai = mkAI()
    local state = baseState()
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 7, col = 6, currentHp = 8, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 1, col = 5, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Wingstalker", player = 1, row = 6, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 2, row = 4, col = 6, currentHp = 3, startingHp = 4, hasActed = false, hasMoved = false}
    }

    ai.getCommandantThreatLookup = function()
        return {
            isUnderAttack = true,
            threatLevel = 180,
            threats = {},
            threatsProjected = {}
        }, {
            ["4,6"] = {threatLevel = 180}
        }
    end

    ai.collectAttackTargetEntries = function()
        return {
            {
                unit = state.units[1],
                target = state.units[2],
                damage = 3,
                targetHp = 3,
                action = {
                    type = "attack",
                    unit = {row = 6, col = 5},
                    target = {row = 4, col = 6}
                }
            }
        }
    end

    ai.findCommandantGuardMove = function()
        return {
            unit = state.units[1],
            action = {
                type = "move",
                unit = {row = 6, col = 5},
                target = {row = 6, col = 6}
            },
            score = 100
        }
    end
    ai.findCommandantDefenseUnblockMove = function()
        return nil
    end
    ai.getPlannedDeploymentCandidate = function()
        return nil
    end

    local bundle = ai:buildDefenseActionBundle(state, {})
    assertTrue(#bundle > 0, "expected defense bundle candidates")
    assertEquals(bundle[1].addTag, "STRATEGIC_DEFENSE_DIRECT_ATTACK", "bundle should prefer neutralization before guard-only move")
end)

runTest("defense_bundle_prefers_direct_over_move_attack_when_same_target_direct_dominates", function()
    local ai = mkAI()
    local state = baseState()
    local directUnit = {name = "Cloudstriker", player = 1, row = 7, col = 7, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    local moveUnit = {name = "Bastion", player = 1, row = 6, col = 6, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    local threat = {name = "Cloudstriker", player = 2, row = 4, col = 7, currentHp = 2, startingHp = 4, hasActed = false, hasMoved = false}
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 7, col = 6, currentHp = 10, startingHp = 12}
    state.units = {directUnit, moveUnit, threat}

    ai.getCommandantThreatLookup = function()
        return {
            isUnderAttack = true,
            threatLevel = 200,
            threats = {},
            threatsProjected = {}
        }, {
            ["4,7"] = {threatLevel = 200}
        }
    end

    ai.collectAttackTargetEntries = function(_, _, _, opts)
        if opts.mode == "direct" then
            return {
                {
                    unit = directUnit,
                    target = threat,
                    damage = 2,
                    targetHp = 2,
                    action = {
                        type = "attack",
                        unit = {row = directUnit.row, col = directUnit.col},
                        target = {row = threat.row, col = threat.col}
                    }
                }
            }
        end
        return {}
    end

    ai.findCommandantThreatMoveAttack = function()
        return {
            unit = moveUnit,
            target = threat,
            moveAction = {
                type = "move",
                unit = {row = moveUnit.row, col = moveUnit.col},
                target = {row = 5, col = 6}
            },
            attackAction = {
                type = "attack",
                unit = {row = 5, col = 6},
                target = {row = threat.row, col = threat.col}
            },
            damage = 1,
            targetHp = 2,
            value = 400
        }
    end

    ai.findThreatCounterAttackMove = function()
        return nil
    end
    ai.findCommandantGuardMove = function()
        return nil
    end
    ai.findCommandantDefenseUnblockMove = function()
        return nil
    end
    ai.getPlannedDeploymentCandidate = function()
        return nil
    end

    local bundle = ai:buildDefenseActionBundle(state, {})
    assertTrue(#bundle > 0, "expected defense bundle candidates")
    assertEquals(bundle[1].addTag, "STRATEGIC_DEFENSE_DIRECT_ATTACK", "direct one-action neutralization should outrank move+attack on same target")
end)

runTest("commandant_move_attack_skips_redundant_reposition_when_direct_attack_exists", function()
    local ai = mkAI()
    local state = baseState()
    local artillery = {name = "Artillery", player = 1, row = 7, col = 3, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false}
    local threat = {name = "Bastion", player = 2, row = 7, col = 5, currentHp = 5, startingHp = 6, hasActed = false, hasMoved = false}
    state.units = {artillery, threat}

    ai.getCommandantThreatLookup = function()
        return {
            isUnderAttack = true,
            threatLevel = 200,
            threats = {},
            threatsProjected = {}
        }, {
            ["7,5"] = {threatLevel = 200}
        }
    end

    ai.collectAttackTargetEntries = function(_, _, _, opts)
        if opts.mode == "direct" then
            return {
                {
                    unit = artillery,
                    target = threat,
                    damage = 2,
                    targetHp = 5,
                    action = {
                        type = "attack",
                        unit = {row = 7, col = 3},
                        target = {row = 7, col = 5}
                    }
                }
            }
        end

        return {
            {
                unit = artillery,
                target = threat,
                damage = 2,
                targetHp = 5,
                moveCell = {row = 7, col = 2},
                moveAction = {
                    type = "move",
                    unit = {row = 7, col = 3},
                    target = {row = 7, col = 2}
                },
                attackAction = {
                    type = "attack",
                    unit = {row = 7, col = 2},
                    target = {row = 7, col = 5}
                }
            }
        }
    end

    ai.isAttackSafe = function()
        return true
    end

    ai.buildProjectedThreatUnit = function(_, unit, row, col)
        local projected = deepCopy(unit)
        projected.row = row
        projected.col = col
        return projected
    end

    ai.getAttackOpportunityContext = function()
        return {}
    end

    ai.getAttackOpportunityScore = function()
        return 100
    end

    local moveAttack = ai:findCommandantThreatMoveAttack(state, {}, {criticalDefense = true})
    assertTrue(moveAttack == nil, "move+attack should be skipped when same direct threat attack already exists")
end)

runTest("strategic_plan_move_avoids_ranged_adjacent_without_turn1_convergence", function()
    local ai = mkAI()
    local state = baseState()
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 10, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12}
    local cloud = {name = "Cloudstriker", player = 1, row = 1, col = 3, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    local enemy = {name = "Crusher", player = 2, row = 4, col = 4, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    state.units = {cloud, enemy}

    ai.strategicPlanState = {
        active = true,
        intent = "SIEGE_SETUP",
        roleAssignments = {
            [ai:getUnitKey(cloud)] = "primary"
        },
        objectiveCells = {
            primary = {row = 4, col = 3}
        }
    }

    ai.collectAttackTargetEntries = function()
        return {}
    end
    ai.getValidMoveCells = function()
        return {
            {row = 4, col = 3}, -- adjacent to enemy (4,4), should be avoided
            {row = 3, col = 3}  -- non-adjacent alternative
        }
    end
    ai.isSuicidalMovement = function()
        return false
    end
    ai.getUnitThreatTiming = function()
        return 2
    end
    ai.getPositionalValue = function()
        return 0
    end
    ai.getPlannedDeploymentCandidate = function()
        return nil
    end

    local entries = ai:buildSiegeActionBundle(state, {})
    assertTrue(#entries > 0, "expected at least one siege advancement entry")

    local moveEntry = nil
    for _, entry in ipairs(entries) do
        if entry.addTag == "STRATEGIC_PLAN_MOVE" then
            moveEntry = entry
            break
        end
    end
    assertTrue(moveEntry ~= nil, "expected a strategic plan move entry")
    assertEquals(moveEntry.action.target.row, 3, "ranged unit should avoid adjacent setup cell without immediate convergence")
    assertEquals(moveEntry.action.target.col, 3, "ranged unit should avoid adjacent setup cell without immediate convergence")
end)

runTest("siege_plan_selects_synergy_package_not_single_unit_drift", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 5
    state.turnNumber = 5
    state.units = {
        {name = "Artillery", player = 1, row = 2, col = 5, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 1, row = 3, col = 5, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 1, row = 4, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = false,
            isUnderProjectedThreat = false,
            threatLevel = 0,
            projectedThreatLevel = 0,
            threats = {},
            threatsProjected = {}
        }
    end

    ai.getUnitThreatTiming = function(_, _, _, _, maxTurns)
        if maxTurns >= 2 then
            return 2, "move_attack"
        end
        return nil, nil
    end

    local plannerState = ai:updateStrategicPlanState(state)
    assertTrue(plannerState.active == true, "expected active siege plan")
    assertEquals(plannerState.packageType, "ARTILLERY_CORVETTE_SCREEN", "expected synergy package selection")
end)

runTest("low_hub_hp_without_detected_threat_does_not_force_defend_hard", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 10
    state.turnNumber = 10
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 6, startingHp = 12}
    state.units = {
        {name = "Artillery", player = 1, row = 2, col = 2, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 1, row = 2, col = 3, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    }

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = false,
            isUnderProjectedThreat = false,
            threatLevel = 0,
            projectedThreatLevel = 0,
            threats = {},
            threatsProjected = {}
        }
    end

    ai.getUnitThreatTiming = function(_, _, _, _, maxTurns)
        if maxTurns >= 2 then
            return 2, "move_attack"
        end
        return nil, nil
    end

    local plannerState = ai:updateStrategicPlanState(state)
    assertTrue(plannerState.intent ~= "DEFEND_HARD", "low hub hp alone should not force hard defense without detected threat")
end)

runTest("plan_advancement_moves_assigned_units_to_objective_cells", function()
    local ai = mkAI()
    local state = baseState()
    local unit = {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    state.units = {unit}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12}

    local unitKey = ai:getUnitKey(unit)
    ai.strategicPlanState = {
        active = true,
        intent = "SIEGE_SETUP",
        roleAssignments = {
            [unitKey] = "primary"
        },
        objectiveCells = {
            primary = {row = 4, col = 2}
        },
        missingRoles = {}
    }

    ai.collectAttackTargetEntries = function()
        return {}
    end
    ai.getValidMoveCells = function()
        return {
            {row = 4, col = 2},
            {row = 2, col = 3}
        }
    end
    ai.isSuicidalMovement = function()
        return false
    end
    ai.getPositionalValue = function()
        return 10
    end
    ai.getPlannedDeploymentCandidate = function()
        return nil
    end

    local bundle = ai:buildSiegeActionBundle(state, {})
    assertTrue(#bundle > 0, "expected siege advancement bundle entries")
    assertEquals(bundle[1].action.type, "move", "expected movement action for plan advancement")
    assertEquals(bundle[1].action.target.row, 4, "expected move toward objective row")
    assertEquals(bundle[1].action.target.col, 2, "expected move toward objective col")
end)

runTest("plan_mode_suppresses_generic_priority14_and_priority19", function()
    local ai = mkAI()
    local paramsCopy = aiConfig.normalizeConfig(deepCopy(aiConfig.AI_PARAMS))
    paramsCopy.SCORES = paramsCopy.SCORES or {}
    paramsCopy.SCORES.STRATEGY = paramsCopy.SCORES.STRATEGY or {}
    paramsCopy.SCORES.STRATEGY.VERIFIER = paramsCopy.SCORES.STRATEGY.VERIFIER or {}
    paramsCopy.SCORES.STRATEGY.VERIFIER.ENABLED = false
    ai.AI_PARAMS = paramsCopy
    ai._scoreConfig = nil

    local state = baseState()
    state.currentTurn = 8
    state.turnNumber = 8
    state.hasDeployedThisTurn = false
    state.supply[1] = {}
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    ai.updateStrategicPlanState = function(selfRef)
        selfRef.strategicPlanState = {
            active = true,
            intent = "SIEGE_SETUP",
            planId = "siege:test",
            planTurnsLeft = 2,
            planScore = 999
        }
        return selfRef.strategicPlanState
    end

    ai.buildSiegeActionBundle = function()
        return {
            {
                kind = "single",
                priority = 900,
                unit = state.units[1],
                action = {
                    type = "move",
                    unit = {row = 2, col = 2},
                    target = {row = 3, col = 2}
                },
                addTag = "STRATEGIC_PLAN_MOVE"
            }
        }
    end

    ai.findBeneficialNoDamageMoves = function()
        return {
            {
                unit = state.units[1],
                action = {
                    type = "move",
                    unit = {row = 2, col = 2},
                    target = {row = 2, col = 3}
                },
                value = 999
            }
        }
    end
    ai.getPlannedDeploymentCandidate = function()
        return {
            type = "supply_deploy",
            unitName = "Cloudstriker",
            unitIndex = 1,
            target = {row = 1, col = 3},
            hub = {row = 1, col = 2},
            score = 999
        }
    end

    local sequence = ai:getBestSequence(state)
    assertTrue(#sequence > 0, "expected sequence under active strategic plan")

    local foundPlanMove = false
    for _, action in ipairs(sequence) do
        if action.type == "move"
            and action.target
            and action.target.row == 3
            and action.target.col == 2 then
            foundPlanMove = true
        end
        assertTrue(action.type ~= "supply_deploy", "plan mode should suppress generic deploy action")
        local isGenericP14Move = action.type == "move"
            and action.target
            and action.target.row == 2
            and action.target.col == 3
        assertTrue(not isGenericP14Move, "plan mode should suppress generic Priority14 move")
    end

    assertTrue(foundPlanMove, "expected strategic plan advancement move in sequence")
end)

runTest("deploy_requires_role_fill_or_immediate_counter_under_plan", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 8
    state.turnNumber = 8
    state.hasDeployedThisTurn = false

    ai.getDeploymentProjectedImpactTurn = function()
        return 1
    end

    ai.strategicPlanState = {
        active = true,
        intent = "SIEGE_SETUP",
        missingRoles = {"screen"}
    }

    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitName = "Artillery",
            unitIndex = 1,
            target = {row = 1, col = 3},
            hub = {row = 1, col = 2},
            score = 100
        }
    end
    assertTrue(
        ai:getPlannedDeploymentCandidate(state, {}) == nil,
        "role-mismatched deployment should be rejected under active siege plan"
    )

    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitName = "Earthstalker",
            unitIndex = 1,
            target = {row = 1, col = 3},
            hub = {row = 1, col = 2},
            score = 100
        }
    end
    assertTrue(
        ai:getPlannedDeploymentCandidate(state, {}) ~= nil,
        "role-filling deployment should be accepted under active siege plan"
    )

    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitName = "Healer",
            unitIndex = 1,
            target = {row = 1, col = 3},
            hub = {row = 1, col = 2},
            score = 100
        }
    end
    assertTrue(
        ai:getPlannedDeploymentCandidate(state, {}) == nil,
        "healer deployment should be rejected outside hard-defense intent"
    )

    ai.strategicPlanState = {
        active = true,
        intent = "DEFEND_HARD",
        missingRoles = {}
    }
    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitName = "Bastion",
            unitIndex = 1,
            target = {row = 1, col = 3},
            hub = {row = 1, col = 2},
            score = 100,
            canCounterThreat = false,
            strategicBonus = 0
        }
    end
    assertTrue(
        ai:getPlannedDeploymentCandidate(state, {}) == nil,
        "defense deployment must neutralize or block threat under hard defense intent"
    )
end)

runTest("deploy_rejects_threatened_before_impact_in_horizon_under_plan", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 8
    state.turnNumber = 8
    state.hasDeployedThisTurn = false

    ai.strategicPlanState = {
        active = true,
        intent = "SIEGE_SETUP",
        missingRoles = {"secondary"}
    }

    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitName = "Cloudstriker",
            unitIndex = 1,
            target = {row = 1, col = 3},
            hub = {row = 1, col = 2},
            score = 100
        }
    end

    ai.getDeploymentProjectedImpactTurn = function()
        return 5
    end

    assertTrue(
        ai:getPlannedDeploymentCandidate(state, {}) == nil,
        "deployment should be rejected when projected impact turn is outside strategy horizon"
    )
end)

runTest("deploy_allows_early_threat_before_impact_when_hub_not_threatened_under_siege_plan", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 8
    state.turnNumber = 8
    state.hasDeployedThisTurn = false

    ai.strategicPlanState = {
        active = true,
        intent = "SIEGE_SETUP",
        missingRoles = {"secondary"}
    }

    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitName = "Cloudstriker",
            unitIndex = 1,
            target = {row = 1, col = 3},
            hub = {row = 1, col = 2},
            score = 100,
            projectedThreatTurn = 1,
            projectedImpactTurn = 2
        }
    end

    ai.getDeploymentProjectedImpactTurn = function()
        return 2
    end

    assertTrue(
        ai:getPlannedDeploymentCandidate(state, {}) ~= nil,
        "deployment should be allowed when timing tie/lead is the only issue and hub is not currently threatened"
    )
end)

runTest("deploy_rejects_early_threat_before_impact_when_hub_threatened_under_siege_plan", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 8
    state.turnNumber = 8
    state.hasDeployedThisTurn = false

    ai.strategicPlanState = {
        active = true,
        intent = "SIEGE_SETUP",
        missingRoles = {"secondary"}
    }

    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitName = "Cloudstriker",
            unitIndex = 1,
            target = {row = 1, col = 3},
            hub = {row = 1, col = 2},
            score = 100,
            projectedThreatTurn = 1,
            projectedImpactTurn = 3
        }
    end

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = false,
            isUnderProjectedThreat = true,
            threatLevel = 120,
            projectedThreatLevel = 120,
            threats = {},
            threatsProjected = {}
        }
    end

    ai.getDeploymentProjectedImpactTurn = function()
        return 3
    end

    assertTrue(
        ai:getPlannedDeploymentCandidate(state, {}) == nil,
        "deployment should be rejected when hub is threatened and threat lead exceeds allowance"
    )
end)

runTest("deploy_allows_threat_tie_impact_when_hub_not_threatened_under_siege_plan", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 8
    state.turnNumber = 8
    state.hasDeployedThisTurn = false

    ai.strategicPlanState = {
        active = true,
        intent = "SIEGE_SETUP",
        missingRoles = {"secondary"}
    }

    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitName = "Cloudstriker",
            unitIndex = 1,
            target = {row = 1, col = 3},
            hub = {row = 1, col = 2},
            score = 100,
            projectedThreatTurn = 1,
            projectedImpactTurn = 1
        }
    end

    ai.getDeploymentProjectedImpactTurn = function()
        return 1
    end

    assertTrue(
        ai:getPlannedDeploymentCandidate(state, {}) ~= nil,
        "deployment tie should be allowed when hub is not currently threatened"
    )
end)

runTest("deploy_rejects_threat_tie_impact_when_hub_threatened_under_siege_plan", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 8
    state.turnNumber = 8
    state.hasDeployedThisTurn = false

    ai.strategicPlanState = {
        active = true,
        intent = "SIEGE_SETUP",
        missingRoles = {"secondary"}
    }

    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitName = "Cloudstriker",
            unitIndex = 1,
            target = {row = 1, col = 3},
            hub = {row = 1, col = 2},
            score = 100,
            projectedThreatTurn = 1,
            projectedImpactTurn = 1
        }
    end

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = true,
            isUnderProjectedThreat = true,
            threatLevel = 220,
            projectedThreatLevel = 90,
            threats = {},
            threatsProjected = {}
        }
    end

    ai.getDeploymentProjectedImpactTurn = function()
        return 1
    end

    assertTrue(
        ai:getPlannedDeploymentCandidate(state, {}) == nil,
        "deployment tie should be rejected when hub is threatened under strict timing"
    )
end)

runTest("determinism_same_seed_same_plan_signature", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 6
    state.turnNumber = 6
    state.units = {
        {name = "Artillery", player = 1, row = 2, col = 5, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 1, row = 3, col = 5, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 1, row = 4, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local result = ai:benchmarkDecisionState(state, 12)
    assertTrue(result.deterministic == true, "strategy planner should keep deterministic action signatures")
    assertEquals(result.uniqueSignatures, 1, "same seeded strategic state should produce one sequence signature")
end)

runTest("planner_budget_guard_falls_back_without_invalid_actions", function()
    local ai = mkAI()
    local paramsCopy = aiConfig.normalizeConfig(deepCopy(aiConfig.AI_PARAMS))
    paramsCopy.SCORES = paramsCopy.SCORES or {}
    paramsCopy.SCORES.STRATEGY = paramsCopy.SCORES.STRATEGY or {}
    paramsCopy.SCORES.STRATEGY.PLANNER_BUDGET_MS = 0
    paramsCopy.SCORES.STRATEGY.MAX_PLAN_CANDIDATES = 50
    ai.AI_PARAMS = paramsCopy
    ai._scoreConfig = nil

    local state = baseState()
    state.currentTurn = 7
    state.turnNumber = 7
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 6, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local sequence = ai:getBestSequence(state)
    assertEquals(#sequence, 2, "planner budget fallback should still return full legal sequence")
    for _, action in ipairs(sequence) do
        assertTrue(type(action) == "table", "fallback sequence action should be a table")
        assertTrue(type(action.type) == "string", "fallback sequence action should have valid type")
    end
end)

runTest("defend_hard_not_triggered_by_low_projected_noise", function()
    local ai = mkAI()
    local state = baseState()

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = false,
            isUnderProjectedThreat = true,
            threatLevel = 60,
            immediateThreatLevel = 0,
            projectedThreatLevel = 60,
            projectedThreatActionable = false,
            projectedThreatActionableScore = 60,
            projectedThreatUnitsInWindow = 1,
            projectedThreatReason = "insufficient_score",
            threats = {},
            threatsProjected = {
                {threatTurn = 1, threatLevel = 60}
            }
        }
    end
    ai.buildBestStrategicPlanCandidate = function()
        return nil
    end

    local intent = ai:computeStrategicIntent(state)
    assertEquals(intent, "STABILIZE", "low projected threat noise should not force DEFEND_HARD")
end)

runTest("defend_hard_enters_on_actionable_projected_threat", function()
    local ai = mkAI()
    local state = baseState()

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = false,
            isUnderProjectedThreat = true,
            threatLevel = 160,
            immediateThreatLevel = 0,
            projectedThreatLevel = 160,
            projectedThreatActionable = true,
            projectedThreatActionableScore = 160,
            projectedThreatUnitsInWindow = 1,
            projectedThreatReason = "meets_threshold",
            threats = {},
            threatsProjected = {
                {threatTurn = 1, threatLevel = 160}
            }
        }
    end

    local intent = ai:computeStrategicIntent(state)
    assertEquals(intent, "DEFEND_HARD", "actionable projected threat should enter DEFEND_HARD")
end)

runTest("defend_hard_hysteresis_prevents_turn_to_turn_flipflop", function()
    local ai = mkAI()
    local state = baseState()
    local calls = 0

    ai.analyzeHubThreat = function()
        calls = calls + 1
        if calls == 1 then
            return {
                isUnderAttack = false,
                isUnderProjectedThreat = true,
                threatLevel = 150,
                immediateThreatLevel = 0,
                projectedThreatLevel = 150,
                projectedThreatActionable = true,
                projectedThreatActionableScore = 150,
                projectedThreatUnitsInWindow = 1,
                projectedThreatReason = "meets_threshold",
                threats = {},
                threatsProjected = {
                    {threatTurn = 1, threatLevel = 150}
                }
            }
        end

        return {
            isUnderAttack = false,
            isUnderProjectedThreat = false,
            threatLevel = 0,
            immediateThreatLevel = 0,
            projectedThreatLevel = 0,
            projectedThreatActionable = false,
            projectedThreatActionableScore = 0,
            projectedThreatUnitsInWindow = 0,
            projectedThreatReason = "none",
            threats = {},
            threatsProjected = {}
        }
    end
    ai.buildBestStrategicPlanCandidate = function()
        return nil
    end

    local intent1 = ai:computeStrategicIntent(state)
    local intent2 = ai:computeStrategicIntent(state)
    local intent3 = ai:computeStrategicIntent(state)

    assertEquals(intent1, "DEFEND_HARD", "initial actionable threat should enter defense mode")
    assertEquals(intent2, "DEFEND_HARD", "hysteresis should hold defense mode on first calm turn")
    assertEquals(intent3, "STABILIZE", "defense mode should exit after hysteresis hold window")
end)

runTest("siege_plan_not_selected_when_score_non_positive", function()
    local ai = mkAI()
    local state = baseState()

    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = false,
            isUnderProjectedThreat = false,
            threatLevel = 0,
            immediateThreatLevel = 0,
            projectedThreatLevel = 0,
            projectedThreatActionable = false,
            projectedThreatActionableScore = 0,
            projectedThreatUnitsInWindow = 0,
            projectedThreatReason = "none",
            threats = {},
            threatsProjected = {}
        }
    end
    ai.buildBestStrategicPlanCandidate = function()
        return {
            score = 0,
            expectedImpactTurn = 1,
            packageType = "ARTILLERY_CORVETTE_SCREEN",
            roleAssignments = {},
            objectiveCells = {}
        }
    end

    local intent = ai:computeStrategicIntent(state)
    assertEquals(intent, "STABILIZE", "non-positive strategic plan score should not activate siege plan")
end)

runTest("defense_deploy_skips_when_all_candidates_bad", function()
    local ai = mkAI()
    local state = baseState()
    ai.strategicPlanState = {
        active = true,
        intent = "DEFEND_HARD"
    }
    ai.findEnhancedSupplyDeployment = function()
        return {
            type = "supply_deploy",
            unitName = "Wingstalker",
            target = {row = 2, col = 2},
            strategicBonus = 0,
            responseBonus = 0,
            canCounterThreat = false,
            score = 10
        }
    end
    ai.analyzeHubThreat = function()
        return {
            isUnderAttack = true,
            projectedThreatActionable = true
        }
    end

    local candidate = ai:getPlannedDeploymentCandidate(state, {})
    assertTrue(candidate == nil, "bad defensive deployment should be skipped")
    assertTrue((ai.badDeploySkipped or 0) >= 1, "bad deploy skip counter should increase")
end)

runTest("nonlethal_attack_requires_non_losing_exchange_or_followup", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 1, row = 3, col = 1, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 2, col = 3, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    ai.calculateDamage = function()
        return 1
    end
    ai.getUnitBaseValue = function(_, unit)
        if unit.player == 1 then
            return 100
        end
        return 120
    end
    ai.wouldUnitDieNextTurn = function(_, _, unit)
        return unit and unit.row == 2 and unit.col == 2
    end
    ai.getUnitThreatTiming = function()
        return nil
    end

    local action = {
        type = "attack",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }

    local unsupported = ai:isNonLethalAttackBacked(state, action, {horizonPlies = 2})
    assertTrue(not unsupported, "non-lethal unsupported attack should be rejected")

    ai.getUnitThreatTiming = function(_, _, unit)
        if unit and unit.player == 1 and not (unit.row == 2 and unit.col == 2) then
            return 1
        end
        return nil
    end

    local supported = ai:isNonLethalAttackBacked(state, action, {horizonPlies = 2})
    assertTrue(supported, "non-lethal attack with follow-up support should be allowed")
end)

runTest("ranged_duel_nonlethal_attack_rejected_when_unfavorable_and_unbacked", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 2, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 2, row = 2, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local action = {
        type = "attack",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 5}
    }

    local allowed, context = ai:isNonLethalAttackBacked(state, action, {
        horizonPlies = 2,
        tempoContext = {phase = "mid"}
    })
    assertTrue(not allowed, "unbacked losing ranged duel should be rejected")
    assertEquals(context.reason, "unsupported_ranged_duel", "expected ranged duel rejection reason")
end)

runTest("ranged_duel_nonlethal_attack_allowed_with_followup_support", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 2, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Artillery", player = 1, row = 5, col = 5, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 2, row = 2, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local action = {
        type = "attack",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 5}
    }

    local allowed, context = ai:isNonLethalAttackBacked(state, action, {
        horizonPlies = 2,
        tempoContext = {phase = "mid"}
    })
    assertTrue(allowed, "ranged duel should be allowed when an ally follow-up exists")
    assertTrue((context.followupAttackers or 0) >= 1, "expected at least one follow-up attacker")
end)

runTest("ranged_duel_evasion_bonus_prefers_retaliation_break_with_posture", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 2, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Artillery", player = 2, row = 2, col = 5, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false}
    }

    local unit = state.units[1]
    local breakBonus = ai:calculateRangedDuelEvasionBonus(state, unit, {row = 1, col = 1}, 1)
    local holdLaneBonus = ai:calculateRangedDuelEvasionBonus(state, unit, {row = 2, col = 3}, 1)
    assertTrue(breakBonus > holdLaneBonus, "duel evasion should prefer move that breaks immediate retaliation while keeping pressure")
    assertTrue(breakBonus > 0, "duel evasion break move should get positive bonus")
end)

runTest("safe_evasion_includes_duel_escape_for_ranged_unit", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 2, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 2, row = 2, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local evasions = ai:findSafeEvasionMoves(state, {})
    assertTrue(#evasions > 0, "expected at least one safe evasion move under losing ranged duel pressure")

    local hasBreakMove = false
    for _, evasion in ipairs(evasions) do
        if evasion.action
            and evasion.action.target
            and evasion.action.target.row == 2
            and evasion.action.target.col == 1 then
            hasBreakMove = true
            break
        end
    end
    assertTrue(hasBreakMove, "safe evasion should include retaliation-break move for pressured ranged unit")
end)

runTest("mandatory_fallback_prefers_non_losing_action_over_solo_suicide_attack", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 3, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    ai.calculateDamage = function()
        return 1
    end
    ai.getUnitBaseValue = function(_, unit)
        if unit.player == 1 then
            return 90
        end
        return 120
    end
    ai.wouldUnitDieNextTurn = function(_, _, unit)
        return unit and unit.player == 1
    end
    ai.getUnitThreatTiming = function()
        return nil
    end

    local fallback = ai:getMandatoryFallbackCandidates(state, {
        includeDeploy = false
    })
    assertTrue(#fallback > 0, "expected fallback candidates")
    assertTrue(not (fallback[1].type == "attack" and fallback[1].unsupportedNonLethal), "unsupported solo attack should not be top fallback choice")
end)

runTest("mandatory_fallback_avoids_lethal_adjacent_move_when_safer_move_exists", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Bastion", player = 1, row = 5, col = 3, currentHp = 2, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Earthstalker", player = 2, row = 6, col = 2, currentHp = 3, startingHp = 4, hasActed = false, hasMoved = false}
    }

    local fallback = ai:getMandatoryFallbackCandidates(state, {
        includeAttack = false,
        includeRepair = false,
        includeDeploy = false
    })
    assertTrue(#fallback > 0, "expected fallback move candidates")
    local top = fallback[1]
    assertEquals(top.type, "move", "expected move fallback")
    assertTrue(not (top.action.target.row == 5 and top.action.target.col == 2), "fallback should avoid moving into immediate lethal adjacent cell")
end)

runTest("verifier_runs_during_siege_and_overrides_losing_line", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 9
    state.turnNumber = 9
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 6, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    ai.updateAdaptiveProfile = function() end
    ai.updateDrawUrgencyState = function() end
    ai.updateThreatReleaseOffenseState = function()
        return {active = false, turnsRemaining = 0}
    end
    ai.updateStrategicPlanState = function(self)
        local plan = {
            active = true,
            intent = "SIEGE_SETUP",
            planId = "siege:test",
            planTurnsLeft = 2,
            planScore = 100
        }
        self.strategicPlanState = plan
        return plan
    end
    ai.findBestAiSequance = function()
        return {
            {type = "move", unit = {row = 2, col = 2}, target = {row = 2, col = 3}}
        }
    end
    ai.sanitizeActionSequenceForState = function(_, _, sequence)
        return sequence, {replacements = 0, reasonCounts = {}}
    end
    ai.collectSequenceCandidates = function(_, _, primarySequence)
        return {
            {sequence = primarySequence, signature = "primary", source = "primary"},
            {
                sequence = {
                    {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}},
                    {type = "skip", unit = {row = 1, col = 1}}
                },
                signature = "alt",
                source = "alt"
            }
        }
    end
    ai.selectVerifiedSequence = function()
        return {
            {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}},
            {type = "skip", unit = {row = 1, col = 1}}
        }, {timedOut = false, evaluated = 2, bestSource = "alt", bestScore = 42}
    end

    local sequence = ai:getBestSequence(state)
    assertEquals(sequence[1].target.row, 3, "verifier should override primary line during siege")
    assertEquals(sequence[1].target.col, 2, "verifier override should keep alternate move target")
    assertTrue((ai.verifierSiegeRuns or 0) >= 1, "siege verifier run counter should increment")
    assertTrue((ai.verifierSiegeOverrides or 0) >= 1, "siege verifier override counter should increment")
end)

runTest("verifier_does_not_drop_attack_without_large_gain", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 3
    state.turnNumber = 3
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    ai.updateAdaptiveProfile = function() end
    ai.updateDrawUrgencyState = function() end
    ai.updateThreatReleaseOffenseState = function()
        return {active = false, turnsRemaining = 0}
    end
    ai.updateStrategicPlanState = function(self)
        local plan = {
            active = true,
            intent = "SIEGE_SETUP",
            planId = "siege:test",
            planTurnsLeft = 2,
            planScore = 100
        }
        self.strategicPlanState = plan
        return plan
    end
    ai.findBestAiSequance = function()
        return {
            {type = "attack", unit = {row = 2, col = 2}, target = {row = 2, col = 5}},
            {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}}
        }
    end
    ai.sanitizeActionSequenceForState = function(_, _, sequence)
        return sequence, {replacements = 0, reasonCounts = {}}
    end
    ai.collectSequenceCandidates = function()
        return {
            {sequence = {{type = "attack", unit = {row = 2, col = 2}, target = {row = 2, col = 5}}}, signature = "primary", source = "primary"},
            {sequence = {{type = "supply_deploy", unitName = "Artillery", target = {row = 1, col = 3}}}, signature = "alt", source = "fallback_variant"}
        }
    end
    ai.selectVerifiedSequence = function()
        return {
            {type = "supply_deploy", unitName = "Artillery", target = {row = 1, col = 3}},
            {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}}
        }, {
            timedOut = false,
            evaluated = 2,
            bestSource = "fallback_variant",
            bestScore = 350,
            primaryScore = 320
        }
    end

    local sequence = ai:getBestSequence(state)
    assertTrue(sequence[1].type == "attack", "verifier should not drop attack lines for marginal score gain")
end)

runTest("verifier_defend_hard_preserves_defense_attack_line", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 8
    state.turnNumber = 8
    state.units = {
        {name = "Bastion", player = 1, row = 3, col = 6, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 2, row = 3, col = 5, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    }

    ai.updateAdaptiveProfile = function() end
    ai.updateDrawUrgencyState = function() end
    ai.updateThreatReleaseOffenseState = function()
        return {active = false, turnsRemaining = 0}
    end
    ai.updateStrategicPlanState = function(self)
        local plan = {
            active = true,
            intent = "DEFEND_HARD",
            planId = "defense:test",
            planTurnsLeft = 1,
            planScore = 0
        }
        self.strategicPlanState = plan
        return plan
    end
    ai.findBestAiSequance = function()
        return {
            {type = "attack", _aiTag = "STRATEGIC_DEFENSE_DIRECT_ATTACK", unit = {row = 3, col = 6}, target = {row = 3, col = 5}},
            {type = "move", _aiTag = "STRATEGIC_DEFENSE_GUARD", unit = {row = 3, col = 6}, target = {row = 4, col = 6}}
        }
    end
    ai.sanitizeActionSequenceForState = function(_, _, sequence)
        return sequence, {replacements = 0, reasonCounts = {}}
    end
    ai.collectSequenceCandidates = function()
        return {
            {
                sequence = {
                    {type = "attack", _aiTag = "STRATEGIC_DEFENSE_DIRECT_ATTACK", unit = {row = 3, col = 6}, target = {row = 3, col = 5}},
                    {type = "move", _aiTag = "STRATEGIC_DEFENSE_GUARD", unit = {row = 3, col = 6}, target = {row = 4, col = 6}}
                },
                signature = "primary",
                source = "primary"
            },
            {
                sequence = {
                    {type = "supply_deploy", unitName = "Artillery", target = {row = 1, col = 6}},
                    {type = "move", unit = {row = 3, col = 6}, target = {row = 2, col = 6}}
                },
                signature = "alt",
                source = "fallback_variant"
            }
        }
    end
    ai.selectVerifiedSequence = function()
        return {
            {type = "supply_deploy", unitName = "Artillery", target = {row = 1, col = 6}},
            {type = "move", unit = {row = 3, col = 6}, target = {row = 2, col = 6}}
        }, {
            timedOut = false,
            evaluated = 2,
            bestSource = "fallback_variant",
            bestScore = 260,
            primaryScore = 200
        }
    end

    local sequence = ai:getBestSequence(state)
    assertTrue(sequence[1].type == "attack", "defend-hard should keep defense attack when verifier gain is marginal")
end)

runTest("collect_candidates_defend_hard_suppresses_fallback_when_primary_has_defense_attack", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 7
    state.turnNumber = 7
    ai.strategicPlanState = {
        active = true,
        intent = "DEFEND_HARD",
        planId = "defense:test",
        planTurnsLeft = 1,
        planScore = 0
    }

    ai.sanitizeActionSequenceForState = function(_, _, sequence)
        return sequence, {replacements = 0, reasonCounts = {}}
    end
    ai.simulateActionSequence = function()
        return state
    end
    ai.getMandatoryFallbackCandidates = function()
        return {
            {action = {type = "supply_deploy", unitName = "Artillery", target = {row = 1, col = 6}}},
            {action = {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}}}
        }
    end

    local primary = {
        {type = "attack", _aiTag = "STRATEGIC_DEFENSE_DIRECT_ATTACK", unit = {row = 3, col = 6}, target = {row = 3, col = 5}},
        {type = "move", _aiTag = "STRATEGIC_DEFENSE_GUARD", unit = {row = 3, col = 6}, target = {row = 4, col = 6}}
    }
    local candidates = ai:collectSequenceCandidates(state, primary, {tempoContext = {phase = "mid"}})
    local sawFallbackVariant = false
    for _, candidate in ipairs(candidates or {}) do
        if candidate.source == "fallback_variant" then
            sawFallbackVariant = true
            break
        end
    end
    assertTrue(not sawFallbackVariant, "fallback variants should be disabled for defend-hard defense-attack primaries")
end)

runTest("mandatory_fallback_prefers_deploy_or_safe_position_over_rock_attack", function()
    local ai = mkAI()
    local state = baseState()
    ai.isStrategicRockAttack = function()
        return false, "no_strategic_impact"
    end
    ai.collectLegalActions = function()
        return {
            {
                type = "attack",
                unit = {name = "Cloudstriker", player = 1, row = 3, col = 2, currentHp = 4, startingHp = 4},
                target = {name = "Rock", player = 0, row = 3, col = 3, currentHp = 5, startingHp = 5},
                action = {type = "attack", unit = {row = 3, col = 2}, target = {row = 3, col = 3}}
            },
            {
                type = "move",
                unit = {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3},
                action = {type = "move", unit = {row = 2, col = 2}, target = {row = 2, col = 3}}
            },
            {
                type = "supply_deploy",
                action = {type = "supply_deploy", unitName = "Bastion", target = {row = 1, col = 2}, score = 80}
            }
        }
    end

    local fallback = ai:getMandatoryFallbackCandidates(state, {})
    assertTrue(#fallback > 0, "expected fallback candidates")
    local top = fallback[1]
    assertTrue(not (top.type == "attack" and top.target and top.target.name == "Rock"), "fallback should prefer deploy/position over filler rock attack")
end)

runTest("rock_attack_selected_only_when_strategic_or_no_alternative", function()
    local ai = mkAI()
    local state = baseState()
    ai.isStrategicRockAttack = function()
        return false, "no_strategic_impact"
    end

    ai.collectLegalActions = function()
        return {
            {
                type = "attack",
                unit = {name = "Cloudstriker", player = 1, row = 3, col = 2, currentHp = 4, startingHp = 4},
                target = {name = "Rock", player = 0, row = 3, col = 3, currentHp = 5, startingHp = 5},
                action = {type = "attack", unit = {row = 3, col = 2}, target = {row = 3, col = 3}}
            },
            {
                type = "move",
                unit = {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3},
                action = {type = "move", unit = {row = 2, col = 2}, target = {row = 2, col = 3}}
            }
        }
    end

    local withAlternative = ai:getMandatoryFallbackCandidates(state, {})
    assertTrue(#withAlternative > 0, "expected fallback candidates with alternative")
    assertTrue(withAlternative[1].type ~= "attack", "non-strategic rock attack should not be top choice when alternatives exist")

    ai.collectLegalActions = function()
        return {
            {
                type = "attack",
                unit = {name = "Cloudstriker", player = 1, row = 3, col = 2, currentHp = 4, startingHp = 4},
                target = {name = "Rock", player = 0, row = 3, col = 3, currentHp = 5, startingHp = 5},
                action = {type = "attack", unit = {row = 3, col = 2}, target = {row = 3, col = 3}}
            }
        }
    end

    local noAlternative = ai:getMandatoryFallbackCandidates(state, {})
    assertTrue(#noAlternative > 0, "expected fallback candidates with only rock attack available")
    assertEquals(noAlternative[1].type, "attack", "rock attack should remain available when there is no alternative")
end)

runTest("supply_deploy_prefers_melee_rescue_when_ranged_ally_is_pinned_adjacent", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 5
    state.turnNumber = 5
    state.hasDeployedThisTurn = false
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 4, col = 4, currentHp = 12, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12}
    state.supply[1] = {
        {name = "Cloudstriker", currentHp = 4, startingHp = 4},
        {name = "Earthstalker", currentHp = 4, startingHp = 4}
    }
    state.units = {
        {name = "Artillery", player = 1, row = 5, col = 4, currentHp = 4, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 5, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local deploys = ai:getPossibleSupplyDeployments(state, true)
    assertTrue(#deploys > 0, "expected supply deployments")
    assertEquals(deploys[1].unitName, "Earthstalker", "adjacent ranged rescue should prioritize melee responder over corvette")
end)

runTest("healer_not_deployed_before_turn5_without_emergency", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 3
    state.turnNumber = 3
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local allowed = ai:isHealerEarlyDeployAllowed(state, 1, {
        isUnderAttack = false,
        projectedThreatActionable = false
    })
    assertTrue(allowed == false, "healer should not deploy before turn 5 without emergency pressure")
end)

runTest("healer_risky_frontline_move_rejected_when_not_offensive", function()
    local ai = mkAI()
    local state = baseState()
    local healer = {name = "Healer", player = 1, row = 6, col = 6, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    state.units = {
        healer,
        {name = "Wingstalker", player = 2, row = 5, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local allowed, reason = ai:isHealerMoveDoctrineAllowed(state, healer, {row = 5, col = 5}, 1, {
        allowEmergencyDefense = false
    })
    assertTrue(allowed == false, "healer frontline move should be rejected in non-offensive posture")
    assertEquals(reason, "frontline", "frontline doctrine rejection should be explicit")
end)

runTest("opening_deploy_uses_adaptive_guardrails_not_random", function()
    local ai = mkAI()
    local supply = {
        {name = "Healer"},
        {name = "Bastion"},
        {name = "Artillery"},
        {name = "Wingstalker"}
    }
    local hubPos = {row = 4, col = 4}

    local selected = ai:getPreferredSupplyUnitIndex(supply, {hubPos = hubPos, turnNumber = 1})
    assertTrue(selected ~= nil, "adaptive opening should always pick a deterministic unit index")
    for _ = 1, 4 do
        local nextPick = ai:getPreferredSupplyUnitIndex(supply, {hubPos = hubPos, turnNumber = 1})
        assertEquals(nextPick, selected, "adaptive opening selection should be deterministic")
    end
    assertTrue(supply[selected].name ~= "Healer", "opening guardrails should block healer in early turns")
end)

runTest("opening_synergy_prefers_balanced_hybrid_core", function()
    local ai = mkAI()
    local supply = {
        {name = "Healer"},
        {name = "Artillery"},
        {name = "Bastion"},
        {name = "Cloudstriker"}
    }

    local selected = ai:getPreferredSupplyUnitIndex(supply, {hubPos = {row = 1, col = 1}, turnNumber = 1})
    assertTrue(selected ~= nil, "expected opening selector to choose a unit")
    local selectedName = supply[selected].name
    assertTrue(selectedName == "Bastion" or selectedName == "Artillery", "opening synergy should favor balanced hybrid anchor core")
end)

runTest("ranged_units_avoid_adjacent_unless_lethal_or_priority00", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 6, currentHp = 1, startingHp = 3, hasActed = false, hasMoved = false}
    }

    ai.getValidMoveCells = function(_, _, row, col)
        if row == 2 and col == 2 then
            return {{row = 2, col = 3}}
        end
        return {}
    end
    ai.getAttackCellsForUnitAtPosition = function()
        return {{row = 2, col = 6}}
    end

    local blocked = ai:collectAttackTargetEntries(state, nil, {
        mode = "move",
        aiPlayer = 1,
        includeFriendlyFireCheck = true,
        requirePositiveDamage = true,
        allowRangedAdjacent = false,
        allowRangedAdjacentIfLethal = false
    })
    assertEquals(#blocked, 0, "ranged move+attack should reject adjacent staging when lethal exception is disabled")

    local allowed = ai:collectAttackTargetEntries(state, nil, {
        mode = "move",
        aiPlayer = 1,
        includeFriendlyFireCheck = true,
        requirePositiveDamage = true,
        allowRangedAdjacent = false,
        allowRangedAdjacentIfLethal = true
    })
    assertTrue(#allowed > 0, "lethal exception should allow adjacent staging for ranged move+attack")
end)

runTest("cloudstriker_hard_standoff_blocks_adjacent_when_escape_exists", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Cloudstriker", player = 1, row = 4, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 4, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local violation = ai:isRangedStandoffViolation(
        state,
        state.units[1],
        {row = 5, col = 5},
        1,
        {
            moveCells = {
                {row = 5, col = 5},
                {row = 2, col = 2}
            },
            threatData = {isUnderAttack = false, projectedThreatActionable = false},
            strategicState = {intent = "SIEGE_SETUP"}
        }
    )
    assertTrue(violation == true, "cloudstriker should not end adjacent to melee threat when non-adjacent escape exists")
end)

runTest("cloudstriker_hard_standoff_allows_adjacent_in_extreme_defense", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Cloudstriker", player = 1, row = 4, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 4, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local violation = ai:isRangedStandoffViolation(
        state,
        state.units[1],
        {row = 5, col = 5},
        1,
        {
            moveCells = {
                {row = 5, col = 5},
                {row = 2, col = 2}
            },
            threatData = {isUnderAttack = true, projectedThreatActionable = true},
            strategicState = {intent = "DEFEND_HARD"}
        }
    )
    assertTrue(violation == false, "extreme defensive context should allow adjacent cloudstriker move")
end)

runTest("squad_support_penalizes_unbacked_forward_push", function()
    local ai = mkAI()
    local movePos = {row = 4, col = 3}

    local supportedState = baseState()
    supportedState.units = {
        {name = "Cloudstriker", player = 1, row = 3, col = 3, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 1, row = 3, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Crusher", player = 2, row = 7, col = 7, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }
    local unsupportedState = deepCopy(supportedState)
    table.remove(unsupportedState.units, 2)

    local supported = ai:scoreStrategicMove(supportedState, supportedState.units[1], movePos, {
        aiPlayer = 1,
        improvement = 40,
        threatValue = 0,
        repairBonus = 0
    })
    local unsupported = ai:scoreStrategicMove(unsupportedState, unsupportedState.units[1], movePos, {
        aiPlayer = 1,
        improvement = 40,
        threatValue = 0,
        repairBonus = 0
    })

    assertTrue(supported.finalScore > unsupported.finalScore, "supported push should outscore unbacked forward push")
end)

runTest("wide_front_mobile_units_prefer_flank_over_stack_lane", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 6
    state.turnNumber = 6
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 4, currentHp = 12, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 8, col = 4, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Artillery", player = 1, row = 1, col = 4, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 1, row = 3, col = 4, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 7, col = 4, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local cloud = state.units[1]
    local flankBonus = ai:calculateWideFrontFlankBonus(state, cloud, {row = 4, col = 2}, 1, {phase = "mid"})
    local stackedBonus = ai:calculateWideFrontFlankBonus(state, cloud, {row = 4, col = 4}, 1, {phase = "mid"})

    assertTrue(flankBonus > stackedBonus, "mobile flanking move should outscore staying in stacked lane")
    assertTrue(flankBonus > 0, "flanking bonus should be positive when decongesting and widening front")

    local bastion = state.units[3]
    local bastionBonus = ai:calculateWideFrontFlankBonus(state, bastion, {row = 4, col = 2}, 1, {phase = "mid"})
    assertEquals(bastionBonus, 0, "wide-front flank bonus should not apply to low-mobility bastion")
end)

runTest("influence_mobile_flow_prefers_cloudstriker_flank_ring", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 6
    state.turnNumber = 6
    state.commandHubs[1] = {name = "Commandant", player = 1, row = 1, col = 4, currentHp = 12, startingHp = 12}
    state.commandHubs[2] = {name = "Commandant", player = 2, row = 8, col = 4, currentHp = 12, startingHp = 12}
    state.units = {
        {name = "Cloudstriker", player = 1, row = 4, col = 4, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 7, col = 4, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    ai.influenceMap = {}
    for row = 1, 8 do
        ai.influenceMap[row] = {}
        for col = 1, 8 do
            ai.influenceMap[row][col] = 0
        end
    end

    ai.influenceMap[4][2] = 160
    ai.influenceMap[3][2] = 140
    ai.influenceMap[5][2] = 130
    ai.influenceMap[4][1] = 110
    ai.influenceMap[4][3] = 95

    ai.influenceMap[5][4] = 45
    ai.influenceMap[5][3] = 10
    ai.influenceMap[5][5] = -20

    local cloud = state.units[1]
    local flankBonus = ai:calculateMobileInfluenceFlowBonus(state, cloud, {row = 4, col = 2}, 1, {phase = "mid"})
    local directBonus = ai:calculateMobileInfluenceFlowBonus(state, cloud, {row = 5, col = 4}, 1, {phase = "mid"})
    assertTrue(flankBonus > directBonus, "cloudstriker should prefer higher influence flank ring over direct low-influence lane")

    local bastion = {name = "Bastion", player = 1, row = 4, col = 4, currentHp = 6, startingHp = 6}
    local nonMobileBonus = ai:calculateMobileInfluenceFlowBonus(state, bastion, {row = 4, col = 2}, 1, {phase = "mid"})
    assertEquals(nonMobileBonus, 0, "influence mobile flow bonus should not apply to low-mobility bastion")
end)

runTest("objective_pathing_melee_prefers_adjacent_route_to_uncontested_target", function()
    local ai = mkAI()
    local state = baseState()
    state.commandHubs[2] = nil
    state.units = {
        {name = "Earthstalker", player = 1, row = 1, col = 1, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 8, col = 1, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local unit = state.units[1]
    local towardBonus = ai:calculateMultiTurnObjectivePathBonus(state, unit, {row = 2, col = 1}, 1, {phase = "mid"})
    local sideBonus = ai:calculateMultiTurnObjectivePathBonus(state, unit, {row = 1, col = 2}, 1, {phase = "mid"})
    assertTrue(towardBonus > sideBonus, "melee objective pathing should favor moves that reduce turns to adjacent attack posture")
end)

runTest("objective_pathing_ranged_prefers_row_col_alignment_route", function()
    local ai = mkAI()
    local state = baseState()
    state.commandHubs[2] = nil
    state.units = {
        {name = "Cloudstriker", player = 1, row = 1, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 8, col = 7, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local unit = state.units[1]
    local alignBonus = ai:calculateMultiTurnObjectivePathBonus(state, unit, {row = 1, col = 6}, 1, {phase = "mid"})
    local offlaneBonus = ai:calculateMultiTurnObjectivePathBonus(state, unit, {row = 1, col = 4}, 1, {phase = "mid"})
    assertTrue(alignBonus > offlaneBonus, "ranged objective pathing should favor row/col alignment toward valid firing lanes")
end)

runTest("objective_pathing_skips_target_when_already_actionable_by_team", function()
    local ai = mkAI()
    local state = baseState()
    state.commandHubs[2] = nil
    state.units = {
        {name = "Earthstalker", player = 1, row = 1, col = 1, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 1, row = 3, col = 1, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Crusher", player = 2, row = 4, col = 1, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local unit = state.units[1]
    local bonus = ai:calculateMultiTurnObjectivePathBonus(state, unit, {row = 2, col = 1}, 1, {phase = "mid"})
    assertEquals(bonus, 0, "pathing bonus should skip objectives that are already actionable this turn by another ally")
end)

runTest("tempo_phase_classifies_early_mid_end_hybrid_supply", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 4
    state.turnNumber = 4
    state.supply[2] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }
    state.units = {
        {name = "Bastion", player = 1, row = 2, col = 2, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 8, col = 8, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local early = ai:getGameTempoPhase(state)
    assertEquals(early.phase, "early", "expected early phase when pre-contact and turn <= 10")

    state.units[2].row = 4
    state.units[2].col = 3
    local midByContact = ai:getGameTempoPhase(state)
    assertEquals(midByContact.phase, "mid", "expected mid phase with contact trigger before turn cutoff")

    state.currentTurn = 12
    state.turnNumber = 12
    local midByTurn = ai:getGameTempoPhase(state)
    assertEquals(midByTurn.phase, "mid", "expected mid phase after turn cutoff")

    state.supply[2] = {}
    local endPhase = ai:getGameTempoPhase(state)
    assertEquals(endPhase.phase, "end", "expected end phase when enemy supply is empty")
end)

runTest("early_balanced_allows_safe_high_value_attack_but_blocks_risky_exposed_move_attack", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 3
    state.turnNumber = 3
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 2, col = 3, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    ai.evaluateAttackSupportAfterAction = function()
        return {
            exchangeDelta = 90,
            followupAttackers = 0,
            targetEliminated = false,
            attackerWillDie = true
        }
    end
    ai.calculateDamage = function()
        return 1
    end

    local blocked = ai:isNonLethalAttackBacked(state, {
        type = "attack",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }, {
        tempoContext = {phase = "early"}
    })
    assertTrue(blocked == false, "early tempo should block unsupported non-lethal attack")

    ai.calculateDamage = function()
        return 7
    end
    local lethalAllowed = ai:isNonLethalAttackBacked(state, {
        type = "attack",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }, {
        tempoContext = {phase = "early"}
    })
    assertTrue(lethalAllowed == true, "lethal tactical attack must stay allowed in early phase")
end)

runTest("opening_dynamic_counter_prefers_response_to_enemy_ranged_lane_pressure", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 1
    state.turnNumber = 1
    state.units = {
        {name = "Artillery", player = 2, row = 6, col = 3, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Cloudstriker", player = 2, row = 6, col = 4, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false}
    }

    local supply = {
        {name = "Bastion"},
        {name = "Wingstalker"},
        {name = "Crusher"}
    }
    local selected = ai:getPreferredSupplyUnitIndex(supply, {
        state = state,
        hubPos = {row = 4, col = 4},
        turnNumber = 1
    })
    assertEquals(supply[selected].name, "Wingstalker", "dynamic opening counter should pick anti-ranged interceptor")
end)

runTest("opening_dynamic_counter_prefers_response_to_enemy_tank_anchor", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 1
    state.turnNumber = 1
    state.units = {
        {name = "Bastion", player = 2, row = 6, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Crusher", player = 2, row = 6, col = 6, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local supply = {
        {name = "Cloudstriker"},
        {name = "Earthstalker"},
        {name = "Crusher"}
    }
    local selected = ai:getPreferredSupplyUnitIndex(supply, {
        state = state,
        hubPos = {row = 4, col = 4},
        turnNumber = 1
    })
    assertEquals(supply[selected].name, "Earthstalker", "dynamic opening counter should pick anti-ground bruiser")
end)

runTest("mid_turn_plus_contact_trigger_activates_before_turn_cutoff", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 5
    state.turnNumber = 5
    state.supply[2] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }
    state.units = {
        {name = "Wingstalker", player = 1, row = 3, col = 3, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 4, col = 3, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    local before = ai.midgameContactTriggerCount or 0
    local context = ai:getPhaseTempoContext(state)
    assertEquals(context.phase, "mid", "contact trigger should transition phase to mid before turn cutoff")
    assertTrue((ai.midgameContactTriggerCount or 0) >= before + 1, "contact trigger telemetry should increment")
end)

runTest("midgame_enables_frequent_supported_interactions", function()
    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 2, col = 3, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }
    ai.evaluateAttackSupportAfterAction = function()
        return {
            exchangeDelta = 80,
            followupAttackers = 0,
            targetEliminated = false,
            attackerWillDie = false
        }
    end
    ai.calculateDamage = function()
        return 1
    end

    state.currentTurn = 3
    state.turnNumber = 3
    local earlyBlocked = ai:isNonLethalAttackBacked(state, {
        type = "attack",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }, {
        tempoContext = {phase = "early"}
    })
    assertTrue(earlyBlocked == false, "early support threshold should reject marginal exchange")

    state.currentTurn = 11
    state.turnNumber = 11
    local midAllowed = ai:isNonLethalAttackBacked(state, {
        type = "attack",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }, {
        tempoContext = {phase = "mid"}
    })
    assertTrue(midAllowed == true, "mid tempo should allow lower-but-positive supported exchange")
end)

runTest("endgame_eta_chooser_selects_faster_hub_kill_path", function()
    local ai = mkAI()
    local state = baseState()
    ai.estimateCommandantKillEta = function()
        return 1
    end
    ai.estimateEliminateAllEta = function()
        return 3
    end
    local choice = ai:chooseEndgameWinPathByEta(state, {horizon = 3})
    assertEquals(choice.path, "hub", "eta chooser should pick hub path when faster")
end)

runTest("endgame_eta_chooser_selects_faster_eliminate_all_path", function()
    local ai = mkAI()
    local state = baseState()
    ai.estimateCommandantKillEta = function()
        return 4
    end
    ai.estimateEliminateAllEta = function()
        return 2
    end
    local choice = ai:chooseEndgameWinPathByEta(state, {horizon = 3})
    assertEquals(choice.path, "wipe", "eta chooser should pick wipe path when faster")
end)

runTest("endgame_finish_first_deploy_skips_non_eta_improving_spawn", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 14
    state.turnNumber = 14
    state.supply[1] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }
    state.supply[2] = {}
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 7, col = 7, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    ai.estimateEndgamePathEta = function()
        return 3
    end
    local score = ai:evaluateSupplyDeployment(state, {name = "Wingstalker"}, {row = 1, col = 2}, {isUnderAttack = false}, {
        unitIndex = 1
    })
    assertTrue(score < -1000, "endgame finish-first should heavily penalize non-improving deploy")
    assertTrue((ai.endgameDeploySkippedCount or 0) >= 1, "endgame deploy skipped counter should increment")
end)

runTest("verifier_early_does_not_replace_attack_line_with_deploy_move_without_required_gain", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 4
    state.turnNumber = 4
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    ai.updateAdaptiveProfile = function() end
    ai.updateDrawUrgencyState = function() end
    ai.updateThreatReleaseOffenseState = function()
        return {active = false, turnsRemaining = 0}
    end
    ai.updateStrategicPlanState = function(self)
        local plan = {
            active = true,
            intent = "SIEGE_SETUP",
            planId = "siege:test",
            planTurnsLeft = 2,
            planScore = 100
        }
        self.strategicPlanState = plan
        return plan
    end
    ai.findBestAiSequance = function()
        return {
            {type = "attack", unit = {row = 2, col = 2}, target = {row = 2, col = 5}},
            {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}}
        }
    end
    ai.sanitizeActionSequenceForState = function(_, _, sequence)
        return sequence, {replacements = 0, reasonCounts = {}}
    end
    ai.collectSequenceCandidates = function()
        return {
            {sequence = {{type = "attack", unit = {row = 2, col = 2}, target = {row = 2, col = 5}}}, signature = "primary", source = "primary"},
            {sequence = {{type = "supply_deploy", unitName = "Artillery", target = {row = 1, col = 3}}}, signature = "alt", source = "fallback_variant"}
        }
    end
    ai.selectVerifiedSequence = function()
        return {
            {type = "supply_deploy", unitName = "Artillery", target = {row = 1, col = 3}},
            {type = "move", unit = {row = 2, col = 2}, target = {row = 3, col = 2}}
        }, {
            timedOut = false,
            evaluated = 2,
            bestSource = "fallback_variant",
            bestScore = 350,
            primaryScore = 320
        }
    end

    local sequence = ai:getBestSequence(state)
    assertTrue(sequence[1].type == "attack", "early verifier guard should keep tactical attack line")
end)

runTest("priority_00_and_01_to_09_ordering_preserved_under_phase_engine", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 6
    state.turnNumber = 6
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 2, col = 3, currentHp = 1, startingHp = 3, hasActed = false, hasMoved = false}
    }

    ai.findWinningConditionActions = function()
        return {
            action = {type = "attack", unit = {row = 2, col = 2}, target = {row = 2, col = 3}},
            unit = {name = "Wingstalker", player = 1, row = 2, col = 2}
        }
    end

    local sequence = ai:findBestAiSequance(state)
    assertTrue(#sequence > 0, "priority pipeline should produce actions")
    assertEquals(sequence[1].type, "attack", "priority00 winning action must stay absolute first")
end)

runTest("determinism_same_seed_same_sequence_signature_with_phase_context", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 8
    state.turnNumber = 8
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 6, col = 6, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    local runtimeSnapshot = {
        positionHistory = deepCopy(ai.positionHistory),
        drawUrgencyMode = deepCopy(ai.drawUrgencyMode),
        threatReleaseOffenseState = deepCopy(ai.threatReleaseOffenseState),
        strategicPlanState = deepCopy(ai.strategicPlanState),
        defenseModeState = deepCopy(ai.defenseModeState)
    }

    local seq1 = ai:getBestSequence(deepCopy(state))
    ai.lastProcessedTurnKey = nil
    ai.lastSequence = nil
    ai.isProcessingTurn = false
    ai.positionHistory = deepCopy(runtimeSnapshot.positionHistory)
    ai.drawUrgencyMode = deepCopy(runtimeSnapshot.drawUrgencyMode)
    ai.threatReleaseOffenseState = deepCopy(runtimeSnapshot.threatReleaseOffenseState)
    ai.strategicPlanState = deepCopy(runtimeSnapshot.strategicPlanState)
    ai.defenseModeState = deepCopy(runtimeSnapshot.defenseModeState)
    local seq2 = ai:getBestSequence(deepCopy(state))
    local sig1 = ai:buildActionSequenceSignature(seq1)
    local sig2 = ai:buildActionSequenceSignature(seq2)
    assertEquals(sig1, sig2, "phase-tempo context should remain deterministic on identical state")
end)

runTest("no_crash_ai_vs_ai_with_phase_engine_enabled", function()
    local ai = mkAI()
    local state = baseState()
    state.currentTurn = 5
    state.turnNumber = 5
    state.supply[1] = {
        {name = "Bastion", currentHp = 6, startingHp = 6},
        {name = "Cloudstriker", currentHp = 4, startingHp = 4}
    }
    state.supply[2] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 6, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 1, row = 3, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 6, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 7, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }

    for _ = 1, 4 do
        local sequence = ai:getBestSequence(state)
        assertTrue(type(sequence) == "table", "sequence should always be produced without crash")
        state = ai:simulateActionSequence(state, sequence)
        state.currentTurn = (state.currentTurn or 5) + 1
        state.turnNumber = state.currentTurn
        ai.lastProcessedTurnKey = nil
        ai.lastSequence = nil
        ai.isProcessingTurn = false
    end
end)

runTest("alias_profile_mapping_applies_expected_reference", function()
    local ai = mkAI()
    local cases = {
        {controller = {id = "preset_ai_1", nickname = "Maggie (AI)"}, expected = "maggie"},
        {controller = {id = "preset_ai_2", nickname = "Burt (AI)"}, expected = "burt"},
        {controller = {id = "preset_ai_3", nickname = "Marge (AI)"}, expected = "marge"},
        {controller = {id = "preset_ai_4", nickname = "Homer (AI)"}, expected = "homer"},
        {controller = {id = "preset_ai_5", nickname = "Lisa (AI)"}, expected = "base"},
        {controller = {id = "preset_ai_6", nickname = "Burns (AI)"}, expected = "burns"},
        {controller = {id = "unknown_alias", nickname = "Marge (AI)"}, expected = "marge"}
    }

    for _, entry in ipairs(cases) do
        local resolved = ai:resolveAiReferenceForController(entry.controller)
        assertEquals(resolved, entry.expected, "alias mapping mismatch")
    end
end)

runTest("lisa_alias_keeps_base_reference_without_override_delta", function()
    local aiBase = mkAI()
    aiBase:setAiReference("base", "regression_base")
    local baseScore = aiBase:getScoreConfig()

    local aiLisa = mkAI()
    local lisaRef = aiLisa:resolveAiReferenceForController({id = "preset_ai_5", nickname = "Lisa (AI)"})
    assertEquals(lisaRef, "base", "Lisa alias should map to base reference")
    aiLisa:setAiReference(lisaRef, "regression_lisa")
    local lisaScore = aiLisa:getScoreConfig()

    assertEquals(
        lisaScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN,
        baseScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN,
        "Lisa reference must keep base early support gain"
    )
    assertEquals(
        lisaScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE,
        baseScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE,
        "Lisa reference must keep base defense trigger threshold"
    )
    assertEquals(
        lisaScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS,
        baseScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS,
        "Lisa reference must keep base threat-release attack bonus"
    )
end)

runTest("burns_alias_mapping_resolves_by_id_and_nickname", function()
    local ai = mkAI()
    local byId = ai:resolveAiReferenceForController({id = "preset_ai_6", nickname = "Burns (AI)"})
    local byNickname = ai:resolveAiReferenceForController({id = "unknown", nickname = "Burns (AI)"})
    assertEquals(byId, "burns", "Burns id alias should resolve to burns")
    assertEquals(byNickname, "burns", "Burns nickname alias should resolve to burns")
end)

runTest("burns_uses_base_when_no_trigger", function()
    local ai = mkAI()
    ai:setAiReference("burns", "burns_neutral")
    local state = baseState()
    state.currentTurn = 3
    state.turnNumber = 3
    state.turnsWithoutDamage = 5
    state.supply[1] = {
        {name = "Cloudstriker", currentHp = 4, startingHp = 4}
    }
    state.supply[2] = {
        {name = "Cloudstriker", currentHp = 4, startingHp = 4}
    }
    state.units = {
        {name = "Bastion", player = 1, row = 2, col = 2, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3},
        {name = "Bastion", player = 2, row = 7, col = 7, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }

    local effective = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
    assertEquals(effective, "base", "Burns should default to base on neutral board")
end)

runTest("burns_switches_to_maggie_in_balanced_contact_state", function()
    local ai = mkAI()
    ai:setAiReference("burns", "burns_contact")
    local state = baseState()
    state.currentTurn = 6
    state.turnNumber = 6
    state.turnsWithoutDamage = 0
    state.units = {
        {name = "Bastion", player = 1, row = 4, col = 4, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3},
        {name = "Bastion", player = 2, row = 4, col = 6, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }
    state.supply[1] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3},
        {name = "Cloudstriker", currentHp = 4, startingHp = 4}
    }
    state.supply[2] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3},
        {name = "Cloudstriker", currentHp = 4, startingHp = 4}
    }

    local effective = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
    assertEquals(effective, "maggie", "Burns should use Maggie profile for balanced contact")
end)

runTest("burns_switches_to_burt_when_advantage_and_pressure", function()
    local ai = mkAI()
    ai:setAiReference("burns", "burns_advantage")
    local state = baseState()
    state.currentTurn = 8
    state.turnNumber = 8
    state.turnsWithoutDamage = 0
    state.commandHubs[1].currentHp = 12
    state.commandHubs[2].currentHp = 6
    state.units = {
        {name = "Bastion", player = 1, row = 4, col = 4, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3},
        {name = "Cloudstriker", player = 1, row = 3, col = 4, currentHp = 4, startingHp = 4, atkDamage = 2, atkRange = 3, move = 3},
        {name = "Bastion", player = 2, row = 4, col = 6, currentHp = 2, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }
    state.supply[1] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3},
        {name = "Cloudstriker", currentHp = 4, startingHp = 4},
        {name = "Artillery", currentHp = 5, startingHp = 5}
    }
    state.supply[2] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }

    local effective = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
    assertEquals(effective, "burt", "Burns should switch to Burt profile with advantage under pressure")
end)

runTest("burns_forces_marge_on_immediate_commandant_threat", function()
    local ai = mkAI()
    ai:setAiReference("burns", "burns_emergency")
    local state = baseState()
    state.currentTurn = 5
    state.turnNumber = 5
    state.commandHubs[1].currentHp = 6
    state.units = {
        {name = "Bastion", player = 1, row = 3, col = 3, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3},
        {name = "Bastion", player = 2, row = 1, col = 2, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }

    local effective = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
    assertEquals(effective, "marge", "Burns must force Marge profile on immediate commandant danger")
end)

runTest("burns_turn_lock_holds_for_two_own_turns_without_emergency", function()
    local ai = mkAI()
    ai:setAiReference("burns", "burns_hold_lock")
    local state = baseState()
    state.commandHubs[1].currentHp = 12
    state.commandHubs[2].currentHp = 6
    state.turnsWithoutDamage = 0
    state.supply[1] = {
        {name = "Cloudstriker", currentHp = 4, startingHp = 4},
        {name = "Bastion", currentHp = 6, startingHp = 6}
    }
    state.supply[2] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }

    state.currentTurn = 7
    state.turnNumber = 7
    state.units = {
        {name = "Cloudstriker", player = 1, row = 4, col = 4, currentHp = 4, startingHp = 4, atkDamage = 2, atkRange = 3, move = 3},
        {name = "Bastion", player = 2, row = 4, col = 6, currentHp = 2, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }
    local t7 = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
    assertEquals(t7, "burt", "Burns should select Burt on turn 7 in advantage state")

    state.currentTurn = 8
    state.turnNumber = 8
    state.commandHubs[2].currentHp = 12
    state.units = {
        {name = "Bastion", player = 1, row = 3, col = 3, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3},
        {name = "Bastion", player = 2, row = 6, col = 6, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }
    state.turnsWithoutDamage = 6
    local t8 = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
    assertEquals(t8, "burt", "Burns should hold Burt for turn 8 due 2-turn lock")
end)

runTest("burns_emergency_override_breaks_hold_lock", function()
    local ai = mkAI()
    ai:setAiReference("burns", "burns_hold_break")
    local state = baseState()
    state.currentTurn = 9
    state.turnNumber = 9
    state.turnsWithoutDamage = 0
    state.commandHubs[1].currentHp = 12
    state.commandHubs[2].currentHp = 6
    state.units = {
        {name = "Cloudstriker", player = 1, row = 4, col = 4, currentHp = 4, startingHp = 4, atkDamage = 2, atkRange = 3, move = 3},
        {name = "Bastion", player = 2, row = 4, col = 6, currentHp = 2, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }
    local initial = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
    assertTrue(initial ~= "marge", "Burns should not start in emergency profile before emergency trigger")

    state.currentTurn = 10
    state.turnNumber = 10
    state.commandHubs[1].currentHp = 5
    state.units = {
        {name = "Bastion", player = 2, row = 1, col = 2, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }
    local emergency = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
    assertEquals(emergency, "marge", "Burns emergency must break lock and force Marge")
end)

runTest("burns_returns_to_rule_selected_profile_after_emergency_clears", function()
    local ai = mkAI()
    ai:setAiReference("burns", "burns_post_emergency")
    local state = baseState()

    state.currentTurn = 11
    state.turnNumber = 11
    state.commandHubs[1].currentHp = 5
    state.units = {
        {name = "Bastion", player = 2, row = 1, col = 2, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }
    local emergency = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
    assertEquals(emergency, "marge", "Burns should be defensive during emergency")

    state.currentTurn = 12
    state.turnNumber = 12
    state.commandHubs[1].currentHp = 12
    state.commandHubs[2].currentHp = 6
    state.turnsWithoutDamage = 0
    state.units = {
        {name = "Cloudstriker", player = 1, row = 4, col = 4, currentHp = 4, startingHp = 4, atkDamage = 2, atkRange = 3, move = 3},
        {name = "Bastion", player = 2, row = 4, col = 6, currentHp = 2, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }
    state.supply[1] = {
        {name = "Cloudstriker", currentHp = 4, startingHp = 4},
        {name = "Bastion", currentHp = 6, startingHp = 6}
    }
    state.supply[2] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }
    local recovered = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
    assertEquals(recovered, "burt", "Burns should resume rule-map profile after emergency clears")
end)

runTest("burt_profile_is_more_aggressive_than_lisa_by_config_thresholds", function()
    local aiLisa = mkAI()
    aiLisa:setAiReference("base", "regression_lisa")
    local lisaScore = aiLisa:getScoreConfig()

    local aiBurt = mkAI()
    aiBurt:setAiReference("burt", "regression_burt")
    local burtScore = aiBurt:getScoreConfig()

    assertTrue(
        burtScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN < lisaScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN,
        "Burt should require less supported gain in early phase"
    )
    assertTrue(
        burtScore.DOCTRINE.EARLY_TEMPO.MAX_EARLY_RISKY_ACTIONS_PER_TURN > lisaScore.DOCTRINE.EARLY_TEMPO.MAX_EARLY_RISKY_ACTIONS_PER_TURN,
        "Burt should allow more early risky actions"
    )
    assertTrue(
        burtScore.DOCTRINE.MID_TEMPO.MID_RISK_BUDGET > lisaScore.DOCTRINE.MID_TEMPO.MID_RISK_BUDGET,
        "Burt should have larger midgame risk budget"
    )
    assertTrue(
        burtScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE > lisaScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE,
        "Burt should enter defend-hard less easily"
    )
    assertTrue(
        burtScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS > lisaScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS,
        "Burt should push stronger threat-release offense"
    )
end)

runTest("marge_profile_is_more_defensive_than_lisa_by_config_thresholds", function()
    local aiLisa = mkAI()
    aiLisa:setAiReference("base", "regression_lisa")
    local lisaScore = aiLisa:getScoreConfig()

    local aiMarge = mkAI()
    aiMarge:setAiReference("marge", "regression_marge")
    local margeScore = aiMarge:getScoreConfig()

    assertTrue(
        margeScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN > lisaScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN,
        "Marge should require higher non-lethal support gain"
    )
    assertTrue(
        margeScore.DOCTRINE.EARLY_TEMPO.MOVE_ATTACK_EXPOSURE_PENALTY > lisaScore.DOCTRINE.EARLY_TEMPO.MOVE_ATTACK_EXPOSURE_PENALTY,
        "Marge should penalize exposed move+attack harder"
    )
    assertTrue(
        margeScore.DOCTRINE.MID_TEMPO.MID_RISK_BUDGET < lisaScore.DOCTRINE.MID_TEMPO.MID_RISK_BUDGET,
        "Marge should reduce midgame risk budget"
    )
    assertTrue(
        margeScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE < lisaScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE,
        "Marge should trigger defend-hard earlier"
    )
    assertTrue(
        margeScore.DOCTRINE.FALLBACK.UNSUPPORTED_NONLETHAL_PENALTY > lisaScore.DOCTRINE.FALLBACK.UNSUPPORTED_NONLETHAL_PENALTY,
        "Marge should punish unsupported non-lethal attacks more"
    )
end)

runTest("maggie_parameters_are_between_lisa_and_burt", function()
    local aiLisa = mkAI()
    aiLisa:setAiReference("base", "regression_lisa")
    local lisaScore = aiLisa:getScoreConfig()

    local aiBurt = mkAI()
    aiBurt:setAiReference("burt", "regression_burt")
    local burtScore = aiBurt:getScoreConfig()

    local aiMaggie = mkAI()
    aiMaggie:setAiReference("maggie", "regression_maggie")
    local maggieScore = aiMaggie:getScoreConfig()

    assertTrue(
        maggieScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN <= lisaScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN
            and maggieScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN >= burtScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN,
        "Maggie early support gain should be between Lisa and Burt"
    )
    assertTrue(
        maggieScore.DOCTRINE.MID_TEMPO.MID_RISK_BUDGET >= lisaScore.DOCTRINE.MID_TEMPO.MID_RISK_BUDGET
            and maggieScore.DOCTRINE.MID_TEMPO.MID_RISK_BUDGET <= burtScore.DOCTRINE.MID_TEMPO.MID_RISK_BUDGET,
        "Maggie mid risk budget should be between Lisa and Burt"
    )
    assertTrue(
        maggieScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS >= lisaScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS
            and maggieScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS <= burtScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS,
        "Maggie threat-release attack bonus should be between Lisa and Burt"
    )
    assertTrue(
        maggieScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE >= lisaScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE
            and maggieScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE <= burtScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE,
        "Maggie defense threshold should be between Lisa and Burt"
    )
end)

runTest("homer_parameters_are_between_lisa_and_marge", function()
    local aiLisa = mkAI()
    aiLisa:setAiReference("base", "regression_lisa")
    local lisaScore = aiLisa:getScoreConfig()

    local aiMarge = mkAI()
    aiMarge:setAiReference("marge", "regression_marge")
    local margeScore = aiMarge:getScoreConfig()

    local aiHomer = mkAI()
    aiHomer:setAiReference("homer", "regression_homer")
    local homerScore = aiHomer:getScoreConfig()

    assertTrue(
        homerScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN >= lisaScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN
            and homerScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN <= margeScore.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN,
        "Homer early support gain should be between Lisa and Marge"
    )
    assertTrue(
        homerScore.DOCTRINE.EARLY_TEMPO.MOVE_ATTACK_EXPOSURE_PENALTY >= lisaScore.DOCTRINE.EARLY_TEMPO.MOVE_ATTACK_EXPOSURE_PENALTY
            and homerScore.DOCTRINE.EARLY_TEMPO.MOVE_ATTACK_EXPOSURE_PENALTY <= margeScore.DOCTRINE.EARLY_TEMPO.MOVE_ATTACK_EXPOSURE_PENALTY,
        "Homer exposure penalty should be between Lisa and Marge"
    )
    assertTrue(
        homerScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE <= lisaScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE
            and homerScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE >= margeScore.STRATEGY.DEFENSE.PROJECTED_TRIGGER_MIN_SCORE,
        "Homer defense threshold should be between Lisa and Marge"
    )
    assertTrue(
        homerScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS <= lisaScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS
            and homerScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS >= margeScore.THREAT_RELEASE_OFFENSE.ATTACK_BONUS,
        "Homer threat-release attack bonus should be between Lisa and Marge"
    )
end)

runTest("ai_vs_ai_reference_switch_invalidates_cached_score_config", function()
    local ai = mkAI()
    ai:setAiReference("base", "cache_ref_base")
    local baseConfig = ai:getScoreConfig()
    assertEquals(ai._scoreConfigReference, "base", "base score cache reference mismatch")

    ai:setAiReference("burt", "cache_ref_burt")
    assertTrue(ai._scoreConfig == nil, "changing reference should clear cached score config")
    local burtConfig = ai:getScoreConfig()
    assertEquals(ai._scoreConfigReference, "burt", "burt score cache reference mismatch")
    assertTrue(baseConfig ~= burtConfig, "score config table should be rebuilt after reference switch")

    ai:setAiReference("base", "cache_ref_reset")
    assertTrue(ai._scoreConfig == nil, "switching back should clear cached score config again")
    local baseConfigAgain = ai:getScoreConfig()
    assertEquals(baseConfigAgain.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN, baseConfig.DOCTRINE.EARLY_TEMPO.MIN_SUPPORTED_ATTACK_GAIN, "base config should be restored after switch back")
end)

runTest("non_burns_aliases_remain_fixed_and_unchanged", function()
    local fixedRefs = {"base", "burt", "maggie", "marge", "homer"}
    local state = baseState()
    state.currentTurn = 9
    state.turnNumber = 9
    state.turnsWithoutDamage = 0
    state.units = {
        {name = "Bastion", player = 1, row = 4, col = 4, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3},
        {name = "Bastion", player = 2, row = 4, col = 5, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }

    for _, ref in ipairs(fixedRefs) do
        local ai = mkAI()
        ai:setAiReference(ref, "fixed_ref_check_" .. ref)
        local effective = ai:getEffectiveAiReference(state, {lock = true, logSwitch = false})
        assertEquals(effective, ref, "fixed alias should keep same effective reference: " .. ref)
    end
end)

runTest("ai_vs_ai_single_instance_uses_per_faction_burns_state_no_cross_bleed", function()
    local ai = mkAI()
    ai:setAiReference("burns", "burns_cross_bleed")

    local stateF1 = baseState()
    stateF1.currentTurn = 6
    stateF1.turnNumber = 6
    stateF1.commandHubs[1].currentHp = 12
    stateF1.commandHubs[2].currentHp = 6
    stateF1.turnsWithoutDamage = 0
    stateF1.units = {
        {name = "Cloudstriker", player = 1, row = 4, col = 4, currentHp = 4, startingHp = 4, atkDamage = 2, atkRange = 3, move = 3},
        {name = "Bastion", player = 2, row = 4, col = 6, currentHp = 2, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }
    stateF1.supply[1] = {
        {name = "Cloudstriker", currentHp = 4, startingHp = 4},
        {name = "Bastion", currentHp = 6, startingHp = 6}
    }
    stateF1.supply[2] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }

    ai.factionId = 1
    local f1Ref = ai:getEffectiveAiReference(stateF1, {lock = true, logSwitch = false})
    assertEquals(f1Ref, "burt", "faction 1 should lock aggressive profile in this scenario")

    local stateF2 = baseState()
    stateF2.currentTurn = 6
    stateF2.turnNumber = 6
    stateF2.commandHubs[2].currentHp = 5
    stateF2.units = {
        {name = "Bastion", player = 1, row = 8, col = 7, currentHp = 6, startingHp = 6, atkDamage = 3, atkRange = 1, move = 3}
    }

    ai.factionId = 2
    local f2Ref = ai:getEffectiveAiReference(stateF2, {lock = true, logSwitch = false})
    assertEquals(f2Ref, "marge", "faction 2 should force defensive profile under emergency")

    ai.factionId = 1
    local f1RefAgain = ai:getEffectiveAiReference(stateF1, {lock = true, logSwitch = false})
    assertEquals(f1RefAgain, "burt", "faction 1 Burns state should be preserved across faction switch")
end)

runTest("determinism_same_seed_same_sequence_signature_per_reference", function()
    local function assertReferenceDeterminism(reference)
        local ai = mkAI()
        ai:setAiReference(reference, "determinism_" .. reference)
        local state = baseState()
        state.currentTurn = 8
        state.turnNumber = 8
        state.units = {
            {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
            {name = "Bastion", player = 1, row = 3, col = 2, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
            {name = "Bastion", player = 2, row = 6, col = 6, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false},
            {name = "Wingstalker", player = 2, row = 7, col = 6, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
        }

        local runtimeSnapshot = {
            positionHistory = deepCopy(ai.positionHistory),
            drawUrgencyMode = deepCopy(ai.drawUrgencyMode),
            threatReleaseOffenseState = deepCopy(ai.threatReleaseOffenseState),
            strategicPlanState = deepCopy(ai.strategicPlanState),
            defenseModeState = deepCopy(ai.defenseModeState)
        }

        local seq1 = ai:getBestSequence(deepCopy(state))
        ai.lastProcessedTurnKey = nil
        ai.lastSequence = nil
        ai.isProcessingTurn = false
        ai.positionHistory = deepCopy(runtimeSnapshot.positionHistory)
        ai.drawUrgencyMode = deepCopy(runtimeSnapshot.drawUrgencyMode)
        ai.threatReleaseOffenseState = deepCopy(runtimeSnapshot.threatReleaseOffenseState)
        ai.strategicPlanState = deepCopy(runtimeSnapshot.strategicPlanState)
        ai.defenseModeState = deepCopy(runtimeSnapshot.defenseModeState)

        local seq2 = ai:getBestSequence(deepCopy(state))
        local sig1 = ai:buildActionSequenceSignature(seq1)
        local sig2 = ai:buildActionSequenceSignature(seq2)
        assertEquals(sig1, sig2, "determinism mismatch for reference " .. reference)
    end

    assertReferenceDeterminism("base")
    assertReferenceDeterminism("burt")
    assertReferenceDeterminism("marge")
end)

runTest("determinism_same_seed_same_sequence_signature_with_burns", function()
    local ai = mkAI()
    ai:setAiReference("burns", "determinism_burns")
    local state = baseState()
    state.currentTurn = 9
    state.turnNumber = 9
    state.turnsWithoutDamage = 0
    state.commandHubs[1].currentHp = 12
    state.commandHubs[2].currentHp = 7
    state.units = {
        {name = "Cloudstriker", player = 1, row = 3, col = 3, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Artillery", player = 1, row = 2, col = 3, currentHp = 5, startingHp = 5, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 6, col = 6, currentHp = 4, startingHp = 6, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 5, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }
    state.supply[1] = {
        {name = "Cloudstriker", currentHp = 4, startingHp = 4},
        {name = "Bastion", currentHp = 6, startingHp = 6}
    }
    state.supply[2] = {
        {name = "Wingstalker", currentHp = 3, startingHp = 3}
    }

    local runtimeSnapshot = {
        positionHistory = deepCopy(ai.positionHistory),
        drawUrgencyMode = deepCopy(ai.drawUrgencyMode),
        threatReleaseOffenseState = deepCopy(ai.threatReleaseOffenseState),
        strategicPlanState = deepCopy(ai.strategicPlanState),
        defenseModeState = deepCopy(ai.defenseModeState),
        dynamicReferenceStateByFaction = deepCopy(ai.dynamicReferenceStateByFaction)
    }

    local seq1 = ai:getBestSequence(deepCopy(state))
    ai.lastProcessedTurnKey = nil
    ai.lastSequence = nil
    ai.isProcessingTurn = false
    ai.positionHistory = deepCopy(runtimeSnapshot.positionHistory)
    ai.drawUrgencyMode = deepCopy(runtimeSnapshot.drawUrgencyMode)
    ai.threatReleaseOffenseState = deepCopy(runtimeSnapshot.threatReleaseOffenseState)
    ai.strategicPlanState = deepCopy(runtimeSnapshot.strategicPlanState)
    ai.defenseModeState = deepCopy(runtimeSnapshot.defenseModeState)
    ai.dynamicReferenceStateByFaction = deepCopy(runtimeSnapshot.dynamicReferenceStateByFaction)

    local seq2 = ai:getBestSequence(deepCopy(state))
    local sig1 = ai:buildActionSequenceSignature(seq1)
    local sig2 = ai:buildActionSequenceSignature(seq2)
    assertEquals(sig1, sig2, "burns determinism mismatch on identical state")
end)

runTest("behavior_smoke_burt_prefers_attack_line_over_guard_in_contact_state", function()
    local state = baseState()
    state.currentTurn = 6
    state.turnNumber = 6
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 2, col = 3, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }
    local action = {type = "attack", unit = {row = 2, col = 2}, target = {row = 2, col = 3}}

    local function configureSupportAi(reference)
        local ai = mkAI()
        ai:setAiReference(reference, "support_" .. reference)
        ai.calculateDamage = function() return 1 end
        ai.evaluateAttackSupportAfterAction = function()
            return {exchangeDelta = 40, followupAttackers = 0}
        end
        ai.isLosingRangedDuelAfterAttack = function()
            return false, {}
        end
        return ai
    end

    local baseAi = configureSupportAi("base")
    local burtAi = configureSupportAi("burt")
    local baseSupported = baseAi:isNonLethalAttackBacked(state, action, {tempoContext = {phase = "mid"}})
    local burtSupported = burtAi:isNonLethalAttackBacked(state, action, {tempoContext = {phase = "mid"}})

    assertTrue(baseSupported == false, "base should reject this non-lethal contact attack")
    assertTrue(burtSupported == true, "burt should accept this non-lethal contact attack")
end)

runTest("behavior_smoke_marge_prefers_guard_or_block_over_risky_attack_same_state", function()
    local state = baseState()
    state.currentTurn = 4
    state.turnNumber = 4
    state.units = {
        {name = "Cloudstriker", player = 1, row = 2, col = 2, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false},
        {name = "Bastion", player = 2, row = 2, col = 3, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false}
    }
    local action = {type = "attack", unit = {row = 2, col = 2}, target = {row = 2, col = 3}}

    local function configureSupportAi(reference)
        local ai = mkAI()
        ai:setAiReference(reference, "support_" .. reference)
        ai.calculateDamage = function() return 1 end
        ai.evaluateAttackSupportAfterAction = function()
            return {exchangeDelta = 140, followupAttackers = 0}
        end
        ai.isLosingRangedDuelAfterAttack = function()
            return false, {}
        end
        return ai
    end

    local baseAi = configureSupportAi("base")
    local margeAi = configureSupportAi("marge")
    local baseSupported = baseAi:isNonLethalAttackBacked(state, action, {tempoContext = {phase = "early"}})
    local margeSupported = margeAi:isNonLethalAttackBacked(state, action, {tempoContext = {phase = "early"}})

    assertTrue(baseSupported == true, "base should allow this supported non-lethal contact attack")
    assertTrue(margeSupported == false, "marge should reject this risky non-lethal contact attack")
end)

runTest("last_game_log_file_created_with_header_on_new_game", function()
    local path = "/tmp/last_game_log_created.txt"
    os.remove(path)

    gameRuler.new({lastGameLogPath = path})
    local content = readAll(path)

    assertTrue(content and #content > 0, "expected LastGameLog file to be created")
    assertTrue(content:find("=== Last Game Log ===", 1, true) ~= nil, "missing LastGameLog header")
    assertTrue(content:find("Started:", 1, true) ~= nil, "missing LastGameLog started timestamp")

    os.remove(path)
end)

runTest("last_game_log_default_path_prefers_love_save_directory_when_available", function()
    _G.love = _G.love or {}
    love.filesystem = love.filesystem or {}

    local previousGetSaveDirectory = love.filesystem.getSaveDirectory
    love.filesystem.getSaveDirectory = function()
        return "/tmp/love_save_dir"
    end

    local gr = gameRuler.new({suppressLastGameLogWarnings = true})
    assertEquals(gr.lastGameLogPath, "/tmp/love_save_dir/LastGameLog.txt", "default log path should use love save directory")

    love.filesystem.getSaveDirectory = previousGetSaveDirectory
end)

runTest("last_game_log_default_uses_love_identity_path_not_cwd", function()
    _G.love = _G.love or {}
    love.filesystem = love.filesystem or {}

    local previousGetSaveDirectory = love.filesystem.getSaveDirectory
    local previousWrite = love.filesystem.write
    local previousAppend = love.filesystem.append

    local writes = {}
    love.filesystem.getSaveDirectory = function()
        return "/tmp/love_identity"
    end
    love.filesystem.write = function(virtualPath, payload)
        writes[#writes + 1] = {kind = "write", path = virtualPath, size = #(payload or "")}
        return true
    end
    love.filesystem.append = function(virtualPath, payload)
        writes[#writes + 1] = {kind = "append", path = virtualPath, size = #(payload or "")}
        return true
    end

    local gr = gameRuler.new({suppressLastGameLogWarnings = true})
    assertEquals(gr.lastGameLogPath, "/tmp/love_identity/LastGameLog.txt", "resolved path should use LOVE identity directory")
    assertTrue(gr.lastGameLogUseLoveFilesystem == true, "default runtime should use love.filesystem for LastGameLog")
    assertTrue(#writes > 0, "expected header write via love.filesystem")
    assertEquals(writes[1].path, "LastGameLog.txt", "virtual log path should avoid cwd/Desktop drift")

    love.filesystem.getSaveDirectory = previousGetSaveDirectory
    love.filesystem.write = previousWrite
    love.filesystem.append = previousAppend
end)

runTest("last_game_log_is_overwritten_when_new_game_starts", function()
    local path = "/tmp/last_game_log_overwrite.txt"
    os.remove(path)

    local gr = gameRuler.new({lastGameLogPath = path})
    gr.currentTurn = 7
    gr.currentPhase = "turn"
    gr.currentTurnPhase = "actions"
    gr:addLogEntryString("P1 Moved CS from C5 to C2")

    local beforeReset = readAll(path) or ""
    assertTrue(beforeReset:find("Cloudstriker", 1, true) ~= nil, "expected pre-reset log content")

    gr:resetGame()

    local afterReset = readAll(path) or ""
    assertTrue(afterReset:find("=== Last Game Log ===", 1, true) ~= nil, "missing header after reset")
    assertTrue(afterReset:find("Cloudstriker", 1, true) == nil, "old game entries should be truncated on reset")

    os.remove(path)
end)

runTest("last_game_log_appends_entries_with_metadata", function()
    local path = "/tmp/last_game_log_metadata.txt"
    os.remove(path)

    local gr = gameRuler.new({lastGameLogPath = path})
    gr.currentTurn = 12
    gr.currentPhase = "turn"
    gr.currentTurnPhase = "actions"
    gr:addLogEntryString("P2 attack BA in B2")

    local content = readAll(path) or ""
    assertTrue(content:find("%[%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%]") ~= nil, "missing wall-clock timestamp")
    assertTrue(content:find("%[T12%]") ~= nil, "missing turn metadata")
    assertTrue(content:find("%[turn/actions%]") ~= nil, "missing phase metadata")
    assertTrue(content:find("%[P2%]") ~= nil, "missing player metadata tag")

    os.remove(path)
end)

runTest("last_game_log_expands_unit_abbreviations_to_full_names", function()
    local path = "/tmp/last_game_log_full_names.txt"
    os.remove(path)

    local gr = gameRuler.new({lastGameLogPath = path})
    gr.currentTurn = 5
    gr.currentPhase = "turn"
    gr.currentTurnPhase = "actions"
    gr:addLogEntryString("P1 Moved CS from C5 to C2")
    gr:addLogEntryString("P2 CH in A1 attack AT in B1")
    gr:addLogEntryString("GAME DRAW AT TURN 10")

    local content = readAll(path) or ""
    assertTrue(content:find("Moved Cloudstriker from C5 to C2", 1, true) ~= nil, "Cloudstriker abbreviation was not expanded")
    assertTrue(content:find("Commandant in A1 attack Artillery in B1", 1, true) ~= nil, "CH/AT abbreviations were not expanded")
    assertTrue(content:find("GAME DRAW AT TURN 10", 1, true) ~= nil, "draw phrase should keep preposition AT")
    assertTrue(content:find("Moved CS from", 1, true) == nil, "CS abbreviation leaked into persistent log")
    assertTrue(content:find("attack AT in", 1, true) == nil, "AT abbreviation leaked into persistent log")
    assertTrue(content:find("CH in A1", 1, true) == nil, "CH abbreviation leaked into persistent log")

    os.remove(path)
end)

runTest("last_game_log_write_failure_does_not_break_turnlog", function()
    local invalidPath = "/tmp/does_not_exist_last_game_log_dir/LastGameLog.txt"
    local gr = gameRuler.new({lastGameLogPath = invalidPath, suppressLastGameLogWarnings = true})
    local ok, err = pcall(function()
        gr:addLogEntryString("P1 this should stay in memory log")
    end)

    assertTrue(ok, "write failure should not raise errors: " .. tostring(err))
    assertTrue(gr.lastGameLogWriteDisabled == true, "write failure should disable persistent writer")
    assertTrue(#gr.turnLog > 0, "turnLog should still receive entries when file writer fails")
end)

runTest("benchmark_determinism_and_budget", function()
    if SKIP_BENCHMARK then
        return
    end

    local ai = mkAI()
    local state = baseState()
    state.units = {
        {name = "Wingstalker", player = 1, row = 2, col = 2, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false},
        {name = "Wingstalker", player = 2, row = 6, col = 6, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false}
    }

    benchmarkResult = ai:benchmarkDecisionState(state, 20)
    local budgetMs = (((aiConfig.AI_PARAMS or {}).RULE_CONTRACT or {}).PERFORMANCE or {}).DECISION_BUDGET_MS or 500

    assertTrue(benchmarkResult.deterministic == true, "benchmark should be deterministic on identical state")
    assertTrue((benchmarkResult.latency.p95Ms or 0) <= budgetMs, "benchmark p95 exceeded budget")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# AI Regression Report"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "- Generated: " .. os.date("%Y-%m-%d %H:%M:%S")
    lines[#lines + 1] = "- Passed: " .. tostring(passCount)
    lines[#lines + 1] = "- Failed: " .. tostring(#results - passCount)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Results"
    lines[#lines + 1] = ""

    for _, result in ipairs(results) do
        local status = result.ok and "PASS" or "FAIL"
        lines[#lines + 1] = string.format("- `%s` %s (%.2fms)", status, result.name, result.ms)
        if not result.ok then
            lines[#lines + 1] = "  - Error: `" .. tostring(result.err):gsub("\n", " ") .. "`"
        end
    end

    if benchmarkResult then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Benchmark Snapshot"
        lines[#lines + 1] = ""
        lines[#lines + 1] = "- Deterministic: `" .. tostring(benchmarkResult.deterministic) .. "`"
        lines[#lines + 1] = "- Unique signatures: `" .. tostring(benchmarkResult.uniqueSignatures) .. "`"
        lines[#lines + 1] = string.format("- Median latency (ms): `%.3f`", benchmarkResult.latency.medianMs or 0)
        lines[#lines + 1] = string.format("- P95 latency (ms): `%.3f`", benchmarkResult.latency.p95Ms or 0)
    end

    return table.concat(lines, "\n")
end

local report = buildReport()
local reportPath = "docs/ai_regression_report.md"
local file = io.open(reportPath, "w")
if file then
    file:write(report)
    file:close()
end

print(report)

local hasFailure = false
for _, result in ipairs(results) do
    if not result.ok then
        hasFailure = true
        break
    end
end

os.exit(hasFailure and 1 or 0)
