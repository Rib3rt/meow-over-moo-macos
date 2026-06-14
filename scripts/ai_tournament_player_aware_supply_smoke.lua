package.path = package.path .. ";./?.lua"

local results = {}

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

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format(
            "%s (expected=%s actual=%s)",
            message or "assertEquals failed",
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

local function ensureHeadlessGlobals()
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
        PERF = {
            LOG_LEVEL = "warn",
            LOG_CATEGORIES = {
                AI = false,
                GAMEPLAY = false,
                GRID = false,
                UI = false,
                PERF = false
            }
        },
        AUDIO = {
            SFX = false,
            SFX_VOLUME = 0
        },
        DISPLAY = {
            WIDTH = 1280,
            HEIGHT = 720,
            SCALE = 1,
            OFFSETX = 0,
            OFFSETY = 0
        }
    }

    _G.DEBUG = _G.DEBUG or {}
    DEBUG.AI = false

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
    GAME.CURRENT.TURN = GAME.CURRENT.TURN or 1
    GAME.CURRENT.MODE = GAME.CURRENT.MODE or GAME.MODE.AI_VS_AI
    GAME.CURRENT.AI_PLAYER_NUMBER = GAME.CURRENT.AI_PLAYER_NUMBER or 1

    GAME.getAIFactionId = GAME.getAIFactionId or function()
        return GAME.CURRENT.AI_PLAYER_NUMBER or 1
    end

    GAME.isFactionControlledByAI = GAME.isFactionControlledByAI or function()
        return true
    end
end

local function unit(name, player, row, col, overrides)
    local defaults = {
        Commandant = 12,
        Wingstalker = 3,
        Crusher = 4,
        Bastion = 6,
        Cloudstriker = 4,
        Earthstalker = 3,
        Healer = 4,
        Artillery = 5
    }

    local hp = defaults[name] or 1
    local u = {
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = hp,
        startingHp = hp,
        hasActed = false,
        hasMoved = false,
        actionsUsed = 0,
        corvetteDamageFlag = false,
        artilleryDamageFlag = false
    }

    for key, value in pairs(overrides or {}) do
        u[key] = value
    end

    return u
end

local function supplyUnit(name)
    local defaults = {
        Commandant = 12,
        Wingstalker = 3,
        Crusher = 4,
        Bastion = 6,
        Cloudstriker = 4,
        Earthstalker = 3,
        Healer = 4,
        Artillery = 5
    }
    local hp = defaults[name] or 1
    return {
        name = name,
        currentHp = hp,
        startingHp = hp
    }
end

local function baseState(opts)
    opts = opts or {}
    local state = {
        phase = "actions",
        turnNumber = opts.turnNumber or 12,
        currentTurn = opts.currentTurn or opts.turnNumber or 12,
        currentPlayer = opts.currentPlayer or 1,
        turnsWithoutDamage = 0,
        hasDeployedThisTurn = opts.hasDeployedThisTurn == true,
        turnActionCount = opts.turnActionCount or 0,
        firstActionRangedAttack = opts.firstActionRangedAttack,
        units = opts.units or {},
        unitsWithRemainingActions = {},
        commandHubs = {
            [1] = opts.hub1 or {name = "Commandant", player = 1, row = 2, col = 2, currentHp = 12, startingHp = 12},
            [2] = opts.hub2 or {name = "Commandant", player = 2, row = 7, col = 7, currentHp = 12, startingHp = 12}
        },
        neutralBuildings = opts.neutralBuildings or {},
        supply = {
            [1] = opts.supply1 or {},
            [2] = opts.supply2 or {}
        },
        attackedObjectivesThisTurn = {},
        guardAssignments = {}
    }

    local hasHubUnit = {
        [1] = false,
        [2] = false
    }

    for _, u in ipairs(state.units) do
        if u.name == "Commandant" and hasHubUnit[u.player] ~= nil then
            hasHubUnit[u.player] = true
        end
    end

    if not hasHubUnit[1] then
        state.units[#state.units + 1] = unit("Commandant", 1, state.commandHubs[1].row, state.commandHubs[1].col, {
            currentHp = state.commandHubs[1].currentHp,
            startingHp = state.commandHubs[1].startingHp
        })
    end
    if not hasHubUnit[2] then
        state.units[#state.units + 1] = unit("Commandant", 2, state.commandHubs[2].row, state.commandHubs[2].col, {
            currentHp = state.commandHubs[2].currentHp,
            startingHp = state.commandHubs[2].startingHp
        })
    end

    return state
end

local function mkAI(factionId)
    local AI = require("ai")
    local ai = AI.new({factionId = factionId})
    ai.grid = {
        getUnitAt = function()
            return nil
        end
    }
    return ai
end

runTest("player_aware_deploy_generation_uses_explicit_player_supply", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local ai = mkAI(1)
    local state = baseState({
        supply1 = {supplyUnit("Bastion")},
        supply2 = {supplyUnit("Cloudstriker")}
    })

    local deployments = ai:getPossibleSupplyDeploymentsForPlayer(state, 2, true, {
        scoreDeployments = false
    })

    assertTrue(#deployments > 0, "expected player 2 deployments")

    for _, deployment in ipairs(deployments) do
        assertEquals(deployment.unitName, "Cloudstriker", "expected only player 2 supply unit in deployments")
        local distToHub = math.abs(deployment.target.row - state.commandHubs[2].row)
            + math.abs(deployment.target.col - state.commandHubs[2].col)
        assertEquals(distToHub, 1, "deployment should be adjacent to player 2 hub")
    end
end)

runTest("player_aware_deploy_application_updates_only_selected_player", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local ai = mkAI(1)
    local state = baseState({
        supply1 = {supplyUnit("Bastion")},
        supply2 = {supplyUnit("Cloudstriker")}
    })

    local deployments = ai:getPossibleSupplyDeploymentsForPlayer(state, 2, true, {
        scoreDeployments = false
    })
    assertTrue(#deployments > 0, "expected player 2 deployment options")

    local selected = deployments[1]
    local newState = ai:applySupplyDeploymentForPlayer(state, selected, 2)
    local deployedUnit = ai:getUnitAtPosition(newState, selected.target.row, selected.target.col)

    assertTrue(deployedUnit ~= nil, "expected deployed unit at target")
    assertEquals(deployedUnit.player, 2, "deployed unit should belong to player 2")
    assertEquals(#newState.supply[2], #state.supply[2] - 1, "player 2 supply should decrease")
    assertEquals(#newState.supply[1], #state.supply[1], "player 1 supply should stay unchanged")
    assertTrue(newState.hasDeployedThisTurn == true, "state should mark deploy as used")
    assertTrue(deployedUnit.hasActed == true, "deployed unit should be marked as acted")
end)

runTest("prepare_state_for_player_turn_resets_only_selected_player", function()
    ensureHeadlessGlobals()

    local ai = mkAI(1)
    local state = baseState({
        hasDeployedThisTurn = true,
        turnActionCount = 2,
        firstActionRangedAttack = {
            attacker = {row = 4, col = 4},
            target = {row = 4, col = 5}
        },
        units = {
            unit("Wingstalker", 1, 4, 4, {hasActed = false, hasMoved = false, actionsUsed = 0}),
            unit("Cloudstriker", 2, 6, 6, {hasActed = true, hasMoved = true, actionsUsed = 2})
        }
    })

    local prepared = ai:prepareStateForPlayerTurn(state, 2)

    assertEquals(prepared.turnActionCount, 0, "turnActionCount should reset")
    assertTrue(prepared.hasDeployedThisTurn == false, "hasDeployedThisTurn should reset")
    assertTrue(prepared.firstActionRangedAttack == nil, "firstActionRangedAttack should clear")

    local p1 = ai:getUnitAtPosition(prepared, 4, 4)
    local p2 = ai:getUnitAtPosition(prepared, 6, 6)

    assertTrue(p1 ~= nil and p2 ~= nil, "expected both units to exist")

    assertTrue(p1.hasActed == false and p1.hasMoved == false and p1.actionsUsed == 0,
        "player 1 unit flags should remain unchanged")
    assertTrue(p2.hasActed == false and p2.hasMoved == false and p2.actionsUsed == 0,
        "player 2 unit flags should be reset")
end)

runTest("player_aware_threat_is_perspective_stable", function()
    ensureHeadlessGlobals()

    local ai = mkAI(1)
    local state = baseState({
        hub1 = {name = "Commandant", player = 1, row = 2, col = 2, currentHp = 12, startingHp = 12},
        hub2 = {name = "Commandant", player = 2, row = 7, col = 7, currentHp = 12, startingHp = 12},
        units = {
            unit("Crusher", 2, 2, 3),
            unit("Cloudstriker", 1, 7, 4)
        }
    })

    local threatP1FromP2 = ai:analyzeHubThreatForPlayer(state, 1, 2, {})
    local threatP2FromP1 = ai:analyzeHubThreatForPlayer(state, 2, 1, {})

    ai.factionId = 2
    local threatP1FromP2AfterSwitch = ai:analyzeHubThreatForPlayer(state, 1, 2, {})
    local threatP2FromP1AfterSwitch = ai:analyzeHubThreatForPlayer(state, 2, 1, {})

    assertTrue(threatP1FromP2.immediateDanger == true, "expected threat to player 1")
    assertTrue(threatP2FromP1.immediateDanger == true, "expected threat to player 2")

    for _, entry in ipairs(threatP1FromP2.damagingAttackers or {}) do
        assertEquals(entry.unit.player, 2, "threat to player 1 should only list player 2 attackers")
    end
    for _, entry in ipairs(threatP2FromP1.damagingAttackers or {}) do
        assertEquals(entry.unit.player, 1, "threat to player 2 should only list player 1 attackers")
    end

    assertEquals(threatP1FromP2.projectedDamage, threatP1FromP2AfterSwitch.projectedDamage,
        "threat projection should not depend on ai.factionId")
    assertEquals(threatP2FromP1.projectedDamage, threatP2FromP1AfterSwitch.projectedDamage,
        "threat projection should not depend on ai.factionId")
end)

runTest("two_action_immediate_lethal_detected_by_player_aware_model", function()
    ensureHeadlessGlobals()

    local ai = mkAI(1)
    local state = baseState({
        hub1 = {name = "Commandant", player = 1, row = 4, col = 4, currentHp = 1, startingHp = 12},
        hub2 = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            unit("Crusher", 2, 4, 6, {hasActed = true, hasMoved = true, actionsUsed = 2})
        },
        supply1 = {},
        supply2 = {}
    })

    local lethal, sequence = ai:hasImmediateCommandantLethal(state, 2, 1, {})
    assertTrue(lethal == true, "expected move+attack lethal to be detected")
    assertTrue(type(sequence) == "table" and #sequence >= 2, "expected lethal line sequence")

    local threat = ai:analyzeHubThreatForPlayer(state, 1, 2, {})
    assertTrue(threat.immediateLethal == true, "threat analysis should report full-turn lethal")

    local hasFullTurnReason = false
    for _, reason in ipairs(threat.reasons or {}) do
        if reason == "full_turn_lethal" then
            hasFullTurnReason = true
            break
        end
    end

    assertTrue(hasFullTurnReason, "expected full_turn_lethal reason in threat report")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Player-Aware Supply/Threat Smoke"
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

    return table.concat(lines, "\n")
end

local report = buildReport()
print(report)

local hasFailure = false
for _, result in ipairs(results) do
    if not result.ok then
        hasFailure = true
        break
    end
end

os.exit(hasFailure and 1 or 0)
