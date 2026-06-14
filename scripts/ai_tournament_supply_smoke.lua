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
        turnNumber = opts.turnNumber or 14,
        currentTurn = opts.currentTurn or opts.turnNumber or 14,
        currentPlayer = opts.currentPlayer or 1,
        turnsWithoutDamage = 0,
        hasDeployedThisTurn = opts.hasDeployedThisTurn == true,
        turnActionCount = opts.turnActionCount or 0,
        firstActionRangedAttack = nil,
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

    local hasHub = {[1] = false, [2] = false}
    for _, u in ipairs(state.units) do
        if u.name == "Commandant" then
            hasHub[u.player] = true
        end
    end

    if not hasHub[1] then
        state.units[#state.units + 1] = unit("Commandant", 1, state.commandHubs[1].row, state.commandHubs[1].col, {
            currentHp = state.commandHubs[1].currentHp,
            startingHp = state.commandHubs[1].startingHp
        })
    end
    if not hasHub[2] then
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

local function tournamentCfg(ai)
    return ai and ai.getTournamentConfig and ai:getTournamentConfig() or {}
end

local function countSupplyByName(list, name)
    local count = 0
    for _, u in ipairs(list or {}) do
        if u and u.name == name then
            count = count + 1
        end
    end
    return count
end

local function hasReason(details, expected)
    for _, reason in ipairs((details and details.reasons) or {}) do
        if reason == expected then
            return true
        end
    end
    return false
end

runTest("enemy_supply_snapshot_and_threat_differs_when_empty", function()
    ensureHeadlessGlobals()

    local reserveModel = require("ai_tournament.reserve_model")
    local ai = mkAI(1)

    local withSupply = baseState({
        supply2 = {supplyUnit("Bastion")}
    })

    local withoutSupply = baseState({
        supply2 = {}
    })

    local snapPresent = reserveModel.snapshotSupplyForPlayer(ai, withSupply, 2, {})
    local snapEmpty = reserveModel.snapshotSupplyForPlayer(ai, withoutSupply, 2, {})

    assertTrue(snapPresent.empty == false, "expected non-empty enemy supply snapshot")
    assertTrue(snapEmpty.empty == true, "expected empty enemy supply snapshot")

    local threatPresent = reserveModel.evaluateEnemyReserveThreat(ai, withSupply, 2, {})
    local threatEmpty = reserveModel.evaluateEnemyReserveThreat(ai, withoutSupply, 2, {})

    assertTrue(threatPresent.empty == false, "enemy reserve threat should be non-empty")
    assertTrue(threatEmpty.empty == true, "enemy reserve threat should be empty")
    assertTrue((threatPresent.value or 0) < (threatEmpty.value or 0), "enemy supply present should increase reserve threat penalty")
end)

runTest("duplicate_supply_names_decrement_only_one_entry", function()
    ensureHeadlessGlobals()

    local ai = mkAI(1)
    local state = baseState({
        supply1 = {
            supplyUnit("Bastion"),
            supplyUnit("Bastion"),
            supplyUnit("Healer")
        }
    })

    local deployments = ai:getPossibleSupplyDeploymentsForPlayer(state, 1, true, {
        scoreDeployments = false
    })

    local selected = nil
    for _, deployment in ipairs(deployments) do
        if deployment.unitName == "Bastion" and deployment.unitIndex == 2 then
            selected = deployment
            break
        end
    end

    assertTrue(selected ~= nil, "expected deploy candidate for duplicate bastion index 2")

    local after = ai:applySupplyDeploymentForPlayer(state, selected, 1)

    assertEquals(#after.supply[1], 2, "expected one supply unit removed")
    assertEquals(countSupplyByName(after.supply[1], "Bastion"), 1, "expected one bastion left after deploying one duplicate")
    assertEquals(countSupplyByName(after.supply[1], "Healer"), 1, "expected healer entry unchanged")
end)

runTest("commandant_pressure_deploy_prefers_surviving_fast_counter", function()
    ensureHeadlessGlobals()

    local threatModel = require("ai_tournament.threat_model")
    local reserveModel = require("ai_tournament.reserve_model")
    local supplyPlanner = require("ai_tournament.supply_planner")

    local ai = mkAI(1)
    local state = baseState({
        hub1 = {name = "Commandant", player = 1, row = 4, col = 4, currentHp = 10, startingHp = 12},
        hub2 = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            unit("Artillery", 2, 4, 7)
        },
        supply1 = {
            supplyUnit("Artillery"),
            supplyUnit("Earthstalker")
        },
        supply2 = {}
    })

    local ctx = {
        cfg = tournamentCfg(ai),
        threatModel = threatModel,
        reserveModel = reserveModel
    }

    local entries = supplyPlanner.getDeployActionEntries(ai, state, 1, ctx)
    assertTrue(#entries > 0, "expected deploy entries")

    local top = entries[1]
    assertEquals(top.action and top.action.unitName, "Earthstalker", "expected anti-ranged commandant counter deploy to outrank artillery")
    assertTrue((top.deployDetails and top.deployDetails.commandantThreatCounter or 0) > 0, "expected positive commandant threat counter score")
    assertTrue(hasReason(top.deployDetails, "commandant_threat_counter_deploy"), "expected commandant threat counter reason")
    assertTrue(top.deployDetails and top.deployDetails.commandantThreatCounterSurvives == true, "expected deployed counter to survive to its attack turn")
    assertEquals(top.deployDetails and top.deployDetails.commandantThreatCounterRoute, "move_attack", "expected selected counter to use explicit move+attack route")
    assertEquals(top.deployDetails and top.deployDetails.commandantThreatCounterEtaActions, 1, "expected selected counter ETA to be one action")

    local artilleryEntry = nil
    for _, entry in ipairs(entries) do
        if entry.action and entry.action.unitName == "Artillery" then
            artilleryEntry = entry
            break
        end
    end
    assertTrue(artilleryEntry ~= nil, "expected artillery deploy entry")
    assertEquals(artilleryEntry.deployDetails and artilleryEntry.deployDetails.commandantThreatCounterRoute, "direct_attack", "expected artillery counter to be marked as direct")
    assertEquals(artilleryEntry.deployDetails and artilleryEntry.deployDetails.commandantThreatCounterEtaActions, 0, "expected direct counter ETA to be zero")
    assertTrue(
        (top.deployDetails.commandantThreatCounterDamage or 0)
            > (artilleryEntry.deployDetails.commandantThreatCounterDamage or 0),
        "expected selected counter to win on higher damage despite slower ETA"
    )
end)

runTest("player_aware_deploy_perspective_breaks_cell_ties", function()
    ensureHeadlessGlobals()

    local threatModel = require("ai_tournament.threat_model")
    local reserveModel = require("ai_tournament.reserve_model")
    local supplyPlanner = require("ai_tournament.supply_planner")

    local ai = mkAI(1)
    local state = baseState({
        hub1 = {name = "Commandant", player = 1, row = 2, col = 2, currentHp = 12, startingHp = 12},
        hub2 = {name = "Commandant", player = 2, row = 7, col = 2, currentHp = 12, startingHp = 12},
        units = {},
        supply1 = {
            supplyUnit("Crusher")
        },
        supply2 = {}
    })

    local ctx = {
        cfg = tournamentCfg(ai),
        threatModel = threatModel,
        reserveModel = reserveModel
    }

    local entries = supplyPlanner.getDeployActionEntries(ai, state, 1, ctx)
    assertTrue(#entries > 0, "expected deploy entries")

    local best = entries[1]
    assertTrue(best.action and best.action.target, "expected target on best deploy")
    assertEquals(best.action.target.row, 3, "expected player-aware deploy to advance toward enemy row")
    assertEquals(best.action.target.col, 2, "expected deterministic forward cell before alphabetical cell tie")
    assertTrue(hasReason(best.deployDetails, "player_aware_deploy_perspective"), "expected perspective reason")
end)

runTest("healer_filler_deploy_gets_heavy_penalty", function()
    ensureHeadlessGlobals()

    local threatModel = require("ai_tournament.threat_model")
    local reserveModel = require("ai_tournament.reserve_model")
    local supplyPlanner = require("ai_tournament.supply_planner")

    local ai = mkAI(1)
    local state = baseState({
        units = {
            unit("Wingstalker", 1, 5, 5),
            unit("Wingstalker", 2, 8, 5)
        },
        supply1 = {
            supplyUnit("Healer")
        },
        supply2 = {}
    })

    local ctx = {
        cfg = tournamentCfg(ai),
        threatModel = threatModel,
        reserveModel = reserveModel
    }

    local entries = supplyPlanner.getDeployActionEntries(ai, state, 1, ctx)
    assertTrue(#entries > 0, "expected deploy entries")

    local healerEntry = nil
    for _, entry in ipairs(entries) do
        if entry.action and entry.action.unitName == "Healer" then
            healerEntry = entry
            break
        end
    end

    assertTrue(healerEntry ~= nil, "expected healer deploy entry")
    assertTrue((healerEntry.cheapScore or 0) <= -2000, "healer filler deploy should be strongly penalized")

    local hasReason = false
    for _, reason in ipairs(((healerEntry.deployDetails or {}).reasons) or {}) do
        if reason == "healer_no_filler" then
            hasReason = true
            break
        end
    end
    assertTrue(hasReason, "healer filler deploy should include healer_no_filler reason")
end)

runTest("bastion_defensive_block_candidate_appears", function()
    ensureHeadlessGlobals()

    local threatModel = require("ai_tournament.threat_model")
    local reserveModel = require("ai_tournament.reserve_model")
    local supplyPlanner = require("ai_tournament.supply_planner")

    local ai = mkAI(1)
    local state = baseState({
        hub1 = {name = "Commandant", player = 1, row = 4, col = 4, currentHp = 3, startingHp = 12},
        hub2 = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            unit("Bastion", 1, 3, 4, {hasActed = true, actionsUsed = 1}),
            unit("Wingstalker", 1, 4, 3, {hasActed = true, actionsUsed = 1}),
            unit("Crusher", 1, 5, 4, {hasActed = true, actionsUsed = 1}),
            unit("Cloudstriker", 2, 4, 7)
        },
        supply1 = {
            supplyUnit("Bastion")
        }
    })

    local ctx = {
        cfg = tournamentCfg(ai),
        threatModel = threatModel,
        reserveModel = reserveModel
    }

    local entries = supplyPlanner.getDeployActionEntries(ai, state, 1, ctx)
    assertTrue(#entries > 0, "expected deploy entries")

    local defensiveCandidate = nil
    for _, entry in ipairs(entries) do
        local action = entry.action or {}
        if action.unitName == "Bastion"
            and action.target
            and action.target.row == 4
            and action.target.col == 5 then
            defensiveCandidate = entry
            break
        end
    end

    assertTrue(defensiveCandidate ~= nil, "expected bastion block candidate at 4,5")
    assertTrue((defensiveCandidate.cheapScore or 0) > 1500, "defensive bastion candidate should score as high-priority")

    local hasDefenseReason = false
    for _, reason in ipairs(((defensiveCandidate.deployDetails or {}).reasons) or {}) do
        if reason == "blocks_commandant_threat" then
            hasDefenseReason = true
            break
        end
    end
    assertTrue(hasDefenseReason, "defensive bastion candidate should include blocks_commandant_threat reason")
end)

runTest("commandant_move_attack_pressure_deploy_prefers_counter_damage", function()
    ensureHeadlessGlobals()

    local threatModel = require("ai_tournament.threat_model")
    local reserveModel = require("ai_tournament.reserve_model")
    local supplyPlanner = require("ai_tournament.supply_planner")

    local ai = mkAI(1)
    local state = baseState({
        turnNumber = 5,
        currentPlayer = 1,
        turnActionCount = 1,
        hub1 = {name = "Commandant", player = 1, row = 1, col = 8, currentHp = 12, startingHp = 12},
        hub2 = {name = "Commandant", player = 2, row = 7, col = 1, currentHp = 12, startingHp = 12},
        units = {
            unit("Artillery", 1, 1, 4, {hasActed = true, actionsUsed = 1}),
            unit("Artillery", 1, 2, 4),
            unit("Bastion", 2, 1, 6, {currentHp = 5}),
            unit("Artillery", 2, 5, 3)
        },
        neutralBuildings = {
            {row = 3, col = 7},
            {row = 4, col = 8},
            {row = 5, col = 7},
            {row = 6, col = 2}
        },
        supply1 = {
            supplyUnit("Bastion"),
            supplyUnit("Crusher"),
            supplyUnit("Earthstalker")
        },
        supply2 = {}
    })

    local ctx = {
        cfg = tournamentCfg(ai),
        threatModel = threatModel,
        reserveModel = reserveModel
    }

    local threat = threatModel.analyzeHubThreatForPlayer(ai, state, 1, 2, ctx)
    assertTrue(threat.immediateDanger == true, "expected enemy bastion to create commandant move-attack pressure")
    assertTrue(threat.fullTurnPressure == true, "expected pressure to be a move-attack, not direct attack")
    assertEquals(
        threat.damagingAttackers[1] and threat.damagingAttackers[1].unit and threat.damagingAttackers[1].unit.name,
        "Bastion",
        "expected move-attack pressure to preserve attacker identity"
    )

    local entries = supplyPlanner.getDeployActionEntries(ai, state, 1, ctx)
    assertTrue(#entries > 0, "expected deploy entries")

    local top = entries[1]
    assertEquals(top.action and top.action.unitName, "Earthstalker", "expected best counter-damage deploy")
    assertEquals(top.action and top.action.target and top.action.target.row, 1, "expected deploy to block the pressure lane")
    assertEquals(top.action and top.action.target and top.action.target.col, 7, "expected deploy to block the pressure lane")
    assertTrue(hasReason(top.deployDetails, "commandant_threat_counter_deploy"), "expected commandant counter reason")
    assertEquals(top.deployDetails and top.deployDetails.commandantThreatCounterDamage, 3, "expected Earthstalker to outdamage alternatives")
    assertTrue(top.deployDetails and top.deployDetails.commandantThreatCounterSurvives == true, "expected counter to survive")

    local crusherEntry = nil
    local bastionEntry = nil
    for _, entry in ipairs(entries) do
        local action = entry.action or {}
        if action.target and action.target.row == 1 and action.target.col == 7 then
            if action.unitName == "Crusher" then
                crusherEntry = entry
            elseif action.unitName == "Bastion" then
                bastionEntry = entry
            end
        end
    end

    assertTrue(crusherEntry ~= nil, "expected crusher alternative")
    assertTrue(bastionEntry ~= nil, "expected bastion alternative")
    assertEquals(crusherEntry.deployDetails and crusherEntry.deployDetails.commandantThreatCounterDamage, 2, "expected crusher to be second counter")
    assertEquals(bastionEntry.deployDetails and bastionEntry.deployDetails.commandantThreatCounterDamage, 0, "expected bastion to have no counter damage")
    assertTrue((top.cheapScore or 0) > (crusherEntry.cheapScore or 0), "expected Earthstalker to outrank Crusher")
    assertTrue((crusherEntry.cheapScore or 0) > (bastionEntry.cheapScore or 0), "expected Crusher to outrank Bastion")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Supply Planner Smoke"
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
