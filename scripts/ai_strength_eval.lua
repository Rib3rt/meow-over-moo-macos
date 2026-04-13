package.path = package.path .. ";./?.lua"

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
        return 1
    end
    GAME.isFactionControlledByAI = GAME.isFactionControlledByAI or function()
        return true
    end
end

ensureGlobals()

local aiConfig = require("ai_config")
local AI = require("ai")
local aiInfluence = require("ai_influence")
local randomGenerator = require("randomGenerator")
local unitsInfo = require("unitsInfo")
local gameRuler = require("gameRuler")

aiInfluence.CONFIG.DEBUG_ENABLED = false

local RULE_CONTRACT = ((aiConfig.AI_PARAMS or {}).RULE_CONTRACT) or {}
local SETUP_RULES = RULE_CONTRACT.SETUP or {}
local TURN_RULES = RULE_CONTRACT.TURN or {}
local ACTION_RULES = RULE_CONTRACT.ACTIONS or {}
local DRAW_RULES = RULE_CONTRACT.DRAW or {}
local PERFORMANCE_RULES = RULE_CONTRACT.PERFORMANCE or {}

local GRID_SIZE = GAME.CONSTANTS.GRID_SIZE
local ACTIONS_PER_TURN = TURN_RULES.ACTIONS_PER_TURN or GAME.CONSTANTS.MAX_ACTIONS_PER_TURN or 2
local DRAW_START_TURN = DRAW_RULES.START_TURN or 10
local DRAW_LIMIT = DRAW_RULES.NO_INTERACTION_LIMIT or GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE or 10

local function parseArgs(argv)
    local opts = {
        matches = 20,
        maxRounds = 120,
        seed = 1337,
        reportPath = "docs/ai_strength_report.md",
        verbose = false,
        p1Ref = "base",
        p2Ref = "base"
    }

    local i = 1
    while i <= #argv do
        local argi = argv[i]
        if argi == "--matches" and argv[i + 1] then
            opts.matches = math.max(1, tonumber(argv[i + 1]) or opts.matches)
            i = i + 2
        elseif argi == "--max-rounds" and argv[i + 1] then
            opts.maxRounds = math.max(1, tonumber(argv[i + 1]) or opts.maxRounds)
            i = i + 2
        elseif argi == "--seed" and argv[i + 1] then
            opts.seed = tonumber(argv[i + 1]) or opts.seed
            i = i + 2
        elseif argi == "--report" and argv[i + 1] then
            opts.reportPath = argv[i + 1]
            i = i + 2
        elseif argi == "--verbose" then
            opts.verbose = true
            i = i + 1
        elseif argi == "--p1-ref" and argv[i + 1] then
            opts.p1Ref = tostring(argv[i + 1])
            i = i + 2
        elseif argi == "--p2-ref" and argv[i + 1] then
            opts.p2Ref = tostring(argv[i + 1])
            i = i + 2
        else
            i = i + 1
        end
    end

    return opts
end

local function deterministicRandomPatch()
    randomGenerator.initialize = function() end
    randomGenerator.forceReinitialize = function() end
    randomGenerator.random = function()
        return math.random()
    end
    randomGenerator.randomInt = function(min, max)
        if min == nil then
            return math.random()
        end
        if max == nil then
            return math.random(min)
        end
        return math.random(min, max)
    end
end

deterministicRandomPatch()

local function percentile(values, ratio)
    if #values == 0 then
        return 0
    end
    local sorted = {}
    for i = 1, #values do
        sorted[i] = values[i]
    end
    table.sort(sorted)
    local index = math.max(1, math.ceil(#sorted * ratio))
    return sorted[index] or 0
end

local function incrementCount(map, key, delta)
    if not map then
        return
    end
    local amount = delta or 1
    map[key] = (map[key] or 0) + amount
end

local function ensureTable(map, key)
    map[key] = map[key] or {}
    return map[key]
end

local function copyUnit(unit)
    local cloned = {}
    for key, value in pairs(unit or {}) do
        cloned[key] = value
    end
    return cloned
end

local function newUnit(unitName, player, row, col)
    local info = unitsInfo:getUnitInfo(unitName)
    if not info then
        error("Unknown unit type: " .. tostring(unitName))
    end

    return {
        name = unitName,
        shortName = info.shortName,
        player = player,
        row = row,
        col = col,
        currentHp = info.startingHp,
        startingHp = info.startingHp,
        fly = info.fly or false,
        atkDamage = info.atkDamage or 0,
        atkRange = info.atkRange or 1,
        move = info.move or 0,
        hasActed = false,
        hasMoved = false,
        actionsUsed = 0,
        corvetteDamageFlag = false,
        artilleryDamageFlag = false
    }
end

local function removeCommandantFromSupply(supplyList)
    for i = #supplyList, 1, -1 do
        if supplyList[i].name == "Commandant" then
            table.remove(supplyList, i)
            return
        end
    end
end

local function buildInitialSupplyForPlayer(player)
    local helper = {
        cleanUnitActionData = function(_, unit)
            unit.hasActed = false
            unit.hasMoved = false
            unit.actionsUsed = 0
            unit.turnActions = {}
            unit.corvetteDamageFlag = false
            unit.artilleryDamageFlag = false
        end
    }

    local supply = gameRuler.createInitialSupply(helper, player) or {}
    local cloned = {}
    for i = 1, #supply do
        local unit = copyUnit(supply[i])
        unit.player = player
        unit.currentHp = unit.currentHp or unit.startingHp or unitsInfo:getUnitHP(unit, "SELF_PLAY_SUPPLY_HP")
        unit.startingHp = unit.startingHp or unitsInfo:getUnitHP(unit, "SELF_PLAY_SUPPLY_HP")
        unit.hasActed = false
        unit.hasMoved = false
        unit.actionsUsed = 0
        cloned[#cloned + 1] = unit
    end
    return cloned
end

local function keyForPos(row, col)
    return tostring(row) .. "," .. tostring(col)
end

local function findUnitAt(state, row, col)
    for _, unit in ipairs(state.units or {}) do
        if unit.row == row and unit.col == col then
            return unit
        end
    end
    return nil
end

local function rebuildNeutralBuildings(state)
    state.neutralBuildings = {}
    for _, unit in ipairs(state.units or {}) do
        if unit.name == "Rock" then
            state.neutralBuildings[#state.neutralBuildings + 1] = {
                row = unit.row,
                col = unit.col,
                currentHp = unit.currentHp or unit.startingHp or 0,
                startingHp = unit.startingHp or 1
            }
        end
    end
end

local function rebuildCommandHubs(state)
    local hubs = {}
    for _, unit in ipairs(state.units or {}) do
        if unit.name == "Commandant" and unit.player and unit.player > 0 then
            hubs[unit.player] = {
                row = unit.row,
                col = unit.col,
                currentHp = unit.currentHp or unit.startingHp or 0,
                startingHp = unit.startingHp or 1
            }
        end
    end
    state.commandHubs = hubs
end

local function rebuildUnitsWithRemainingActions(state)
    state.unitsWithRemainingActions = {}
    for _, unit in ipairs(state.units or {}) do
        if unit.player == state.currentPlayer and unit.name ~= "Commandant" and not unit.hasActed then
            state.unitsWithRemainingActions[#state.unitsWithRemainingActions + 1] = {
                row = unit.row,
                col = unit.col,
                name = unit.name,
                player = unit.player
            }
        end
    end
end

local function refreshDerivedState(state)
    rebuildCommandHubs(state)
    rebuildNeutralBuildings(state)
    rebuildUnitsWithRemainingActions(state)
    return state
end

local function playerHasUnitsOrSupply(state, player)
    for _, unit in ipairs(state.units or {}) do
        if unit.player == player and unit.name ~= "Commandant" and unit.name ~= "Rock" then
            local hp = unit.currentHp or unit.startingHp or 0
            if hp > 0 then
                return true
            end
        end
    end

    local supply = state.supply and state.supply[player] or {}
    for _, unit in ipairs(supply or {}) do
        local hp = unit.currentHp or unit.startingHp or 0
        if hp > 0 and unit.name ~= "Commandant" then
            return true
        end
    end

    return false
end

local function unitActionResetForPlayer(state, player)
    for _, unit in ipairs(state.units or {}) do
        if unit.player == player then
            unit.hasActed = false
            unit.hasMoved = false
            unit.actionsUsed = 0
            unit.turnActions = {}
            unit.corvetteDamageFlag = false
            unit.artilleryDamageFlag = false
        end
    end
end

local function setupGridAdapter(ai, stateRef)
    ai.grid = {
        rows = GRID_SIZE,
        cols = GRID_SIZE,
        movingUnits = {},
        getUnitAt = function(_, row, col)
            return findUnitAt(stateRef.state, row, col)
        end,
        getCell = function(_, row, col)
            return {unit = findUnitAt(stateRef.state, row, col)}
        end,
        isCellEmpty = function(_, row, col)
            if row < 1 or row > GRID_SIZE or col < 1 or col > GRID_SIZE then
                return false
            end
            return findUnitAt(stateRef.state, row, col) == nil
        end,
        isValidPosition = function(_, row, col)
            return row >= 1 and row <= GRID_SIZE and col >= 1 and col <= GRID_SIZE
        end,
        clearHighlightedCells = function() end,
        clearForcedHighlightedCells = function() end,
        clearActionHighlights = function() end,
        addAIDecisionEffect = function() end
    }

    ai.gameRuler = ai.gameRuler or {}
    ai.gameRuler.currentPlayer = stateRef.state.currentPlayer
    ai.gameRuler.player1Supply = stateRef.state.supply and stateRef.state.supply[1] or {}
    ai.gameRuler.player2Supply = stateRef.state.supply and stateRef.state.supply[2] or {}
end

local function placeObstacleRows(state, occupied)
    local obstacleRules = SETUP_RULES.OBSTACLES or {}
    local rows = obstacleRules.ROWS or {3, 4, 5, 6}

    for _, row in ipairs(rows) do
        local placed = false
        local attempts = 0
        while not placed and attempts < 100 do
            local col = math.random(1, GRID_SIZE)
            local posKey = keyForPos(row, col)
            if not occupied[posKey] then
                occupied[posKey] = true
                local rock = newUnit("Rock", 0, row, col)
                state.units[#state.units + 1] = rock
                placed = true
            end
            attempts = attempts + 1
        end
        if not placed then
            error("Failed to place obstacle in row " .. tostring(row))
        end
    end
end

local function placeCommandantForPlayer(state, occupied, player)
    local zone = (SETUP_RULES.COMMANDANT_ZONE or {})[player] or {}
    local minRow = zone.MIN_ROW or (player == 1 and 1 or 7)
    local maxRow = zone.MAX_ROW or (player == 1 and 2 or 8)

    local placed = false
    local attempts = 0
    while not placed and attempts < 200 do
        local row = math.random(minRow, maxRow)
        local col = math.random(1, GRID_SIZE)
        local posKey = keyForPos(row, col)
        if not occupied[posKey] then
            occupied[posKey] = true
            local commandant = newUnit("Commandant", player, row, col)
            state.units[#state.units + 1] = commandant
            state.commandHubs[player] = {
                row = row,
                col = col,
                currentHp = commandant.currentHp,
                startingHp = commandant.startingHp
            }
            placed = true
        end
        attempts = attempts + 1
    end
    if not placed then
        error("Failed to place Commandant for player " .. tostring(player))
    end
end

local function actionMatches(a, b)
    if not a or not b then
        return false
    end
    if a.type ~= b.type then
        return false
    end

    local function posEqual(p1, p2)
        if not p1 or not p2 then
            return false
        end
        return p1.row == p2.row and p1.col == p2.col
    end

    if a.type == "supply_deploy" then
        return (a.unitIndex == b.unitIndex) and posEqual(a.target, b.target)
    end

    return posEqual(a.unit, b.unit) and posEqual(a.target, b.target)
end

local function normalizeActionForState(ai, state, player, proposedAction)
    local legalEntries = ai:collectLegalActions(state, {
        aiPlayer = player,
        allowFullHpHealerRepairException = ACTION_RULES.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    })

    if #legalEntries == 0 then
        return {type = "skip", unit = {row = 1, col = 1}}, false, "no_legal_actions"
    end

    local legalActions = {}
    for _, entry in ipairs(legalEntries) do
        legalActions[#legalActions + 1] = entry.action
    end

    if proposedAction and proposedAction.type ~= "skip" then
        for _, legalAction in ipairs(legalActions) do
            if actionMatches(proposedAction, legalAction) then
                return proposedAction, false, "as_selected"
            end
        end
    end

    local fallback = ai:getMandatoryFallbackCandidates(state, {
        aiPlayer = player,
        allowFullHpHealerRepairException = ACTION_RULES.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    })

    if fallback[1] and fallback[1].action then
        return fallback[1].action, true, "fallback_replacement"
    end

    return {type = "skip", unit = {row = 1, col = 1}}, true, "skip_fallback"
end

local function applyActionToState(ai, state, action, player)
    if not action or action.type == "skip" then
        return state, false
    end

    local interaction = false
    if action.type == "attack" then
        local target = findUnitAt(state, action.target.row, action.target.col)
        if target and target.player ~= player then
            interaction = true
        end
        state = ai:applyMove(state, action)
    elseif action.type == "move" or action.type == "repair" then
        state = ai:applyMove(state, action)
    elseif action.type == "supply_deploy" then
        state = ai:applySupplyDeployment(state, action)
    end

    refreshDerivedState(state)
    return state, interaction
end

local function executeCommandantPhase(state, player)
    local hub = state.commandHubs and state.commandHubs[player]
    if not hub then
        return state, false, nil
    end

    local commandant = findUnitAt(state, hub.row, hub.col)
    if not commandant then
        return state, false, nil
    end

    local interaction = false
    local directions = {
        {row = 0, col = 1},
        {row = 1, col = 0},
        {row = 0, col = -1},
        {row = -1, col = 0}
    }

    for _, dir in ipairs(directions) do
        local targetRow = hub.row + dir.row
        local targetCol = hub.col + dir.col
        local target = findUnitAt(state, targetRow, targetCol)
        if target and target.player ~= player and target.player ~= 0 then
            interaction = true
            local damage = unitsInfo:calculateAttackDamage(commandant, target)
            local hp = target.currentHp or target.startingHp or 1
            target.currentHp = math.max(0, hp - damage)
            if target.currentHp <= 0 then
                for i = #state.units, 1, -1 do
                    local unit = state.units[i]
                    if unit.row == targetRow and unit.col == targetCol then
                        table.remove(state.units, i)
                        break
                    end
                end
                if target.name == "Commandant" then
                    refreshDerivedState(state)
                    return state, interaction, player
                end
            end
        end
    end

    refreshDerivedState(state)
    return state, interaction, nil
end

local function pickInitialDeployment(ai, state, player)
    local deployments = ai:getPossibleSupplyDeployments(state, true)
    if #deployments > 0 then
        return deployments[1]
    end

    local hub = state.commandHubs[player]
    local supply = state.supply[player]
    if not hub or not supply or #supply == 0 then
        return nil
    end

    local dirs = {
        {row = 1, col = 0},
        {row = -1, col = 0},
        {row = 0, col = 1},
        {row = 0, col = -1}
    }
    for unitIndex = 1, #supply do
        for _, dir in ipairs(dirs) do
            local row = hub.row + dir.row
            local col = hub.col + dir.col
            if row >= 1 and row <= GRID_SIZE and col >= 1 and col <= GRID_SIZE and not findUnitAt(state, row, col) then
                return {
                    type = "supply_deploy",
                    unitIndex = unitIndex,
                    unitName = supply[unitIndex].name,
                    target = {row = row, col = col},
                    hub = {row = hub.row, col = hub.col},
                    score = 0
                }
            end
        end
    end
    return nil
end

local function createInitialState(seed, ai1, ai2)
    math.randomseed(seed)

    local state = {
        phase = "actions",
        turnNumber = 1,
        currentTurn = 1,
        currentPlayer = 1,
        turnsWithoutDamage = 0,
        hasDeployedThisTurn = false,
        turnActionCount = 0,
        firstActionRangedAttack = nil,
        units = {},
        unitsWithRemainingActions = {},
        commandHubs = {},
        neutralBuildings = {},
        supply = {
            [1] = buildInitialSupplyForPlayer(1),
            [2] = buildInitialSupplyForPlayer(2)
        },
        attackedObjectivesThisTurn = {},
        guardAssignments = {}
    }

    local occupied = {}
    placeObstacleRows(state, occupied)
    placeCommandantForPlayer(state, occupied, 1)
    placeCommandantForPlayer(state, occupied, 2)
    removeCommandantFromSupply(state.supply[1])
    removeCommandantFromSupply(state.supply[2])
    refreshDerivedState(state)

    local stateRef = {state = state}
    setupGridAdapter(ai1, stateRef)
    setupGridAdapter(ai2, stateRef)

    state.currentPlayer = 1
    local p1Deploy = pickInitialDeployment(ai1, state, 1)
    if p1Deploy then
        state = ai1:applySupplyDeployment(state, p1Deploy)
        refreshDerivedState(state)
    end
    state.hasDeployedThisTurn = false

    state.currentPlayer = 2
    local p2Deploy = pickInitialDeployment(ai2, state, 2)
    if p2Deploy then
        state = ai2:applySupplyDeployment(state, p2Deploy)
        refreshDerivedState(state)
    end
    state.hasDeployedThisTurn = false

    for _, unit in ipairs(state.units) do
        unit.hasActed = false
        unit.hasMoved = false
        unit.actionsUsed = 0
        unit.turnActions = {}
    end

    state.currentPlayer = 1
    state.currentTurn = 1
    state.turnNumber = 1
    state.turnsWithoutDamage = 0
    state.turnActionCount = 0
    state.firstActionRangedAttack = nil
    state.attackedObjectivesThisTurn = {}
    refreshDerivedState(state)
    return state
end

local function runMatch(matchIndex, opts)
    local matchSeed = opts.seed + (matchIndex * 7919)
    local ai1 = AI.new({factionId = 1})
    local ai2 = AI.new({factionId = 2})
    ai1:setAiReference(opts.p1Ref, "strength_eval_p1")
    ai2:setAiReference(opts.p2Ref, "strength_eval_p2")

    local state = createInitialState(matchSeed, ai1, ai2)
    local stateRef = {state = state}
    setupGridAdapter(ai1, stateRef)
    setupGridAdapter(ai2, stateRef)

    local currentPlayer = 1
    local round = 1
    local winner = nil
    local outcome = "draw"
    local reason = "max_round_cap"
    local playerTurns = 0
    local decisionLatencies = {}
    local actionReplacements = 0
    local replacementReasonCounts = {}
    local actionTypeCounts = {}
    local actionTypeCountsByPlayer = {[1] = {}, [2] = {}}
    local unitUsageByPlayer = {[1] = {}, [2] = {}}
    local interactionCounter = state.turnsWithoutDamage or 0

    local function recordUnitAction(player, unitName, actionType)
        local resolvedPlayer = player or 0
        local resolvedType = actionType or "unknown"
        local resolvedUnitName = unitName or "UNKNOWN"

        incrementCount(actionTypeCounts, resolvedType, 1)
        incrementCount(actionTypeCountsByPlayer[resolvedPlayer], resolvedType, 1)

        local playerUsage = ensureTable(unitUsageByPlayer, resolvedPlayer)
        local unitEntry = ensureTable(playerUsage, resolvedUnitName)
        incrementCount(unitEntry, "total", 1)
        incrementCount(unitEntry, resolvedType, 1)
    end

    while true do
        state.currentPlayer = currentPlayer
        state.currentTurn = round
        state.turnNumber = round
        GAME.CURRENT.TURN = round
        GAME.CURRENT.AI_PLAYER_NUMBER = currentPlayer

        if not playerHasUnitsOrSupply(state, currentPlayer) then
            winner = (currentPlayer == 1) and 2 or 1
            outcome = "win"
            reason = "no_units_or_supply"
            break
        end

        unitActionResetForPlayer(state, currentPlayer)
        state.hasDeployedThisTurn = false
        state.turnActionCount = 0
        state.firstActionRangedAttack = nil
        state.attackedObjectivesThisTurn = {}
        refreshDerivedState(state)

        local turnInteraction = false
        local phaseWinner = nil

        state, turnInteraction, phaseWinner = executeCommandantPhase(state, currentPlayer)
        if phaseWinner then
            winner = phaseWinner
            outcome = "win"
            reason = "commandant_phase_kill"
            break
        end

        local opponent = (currentPlayer == 1) and 2 or 1
        if not playerHasUnitsOrSupply(state, opponent) then
            winner = currentPlayer
            outcome = "win"
            reason = "opponent_no_units_or_supply"
            break
        end

        local ai = (currentPlayer == 1) and ai1 or ai2
        setupGridAdapter(ai, stateRef)
        ai.gameRuler.currentPlayer = currentPlayer

        local started = os.clock()
        local sequence = ai:getBestSequence(state)
        local latencyMs = (os.clock() - started) * 1000
        decisionLatencies[#decisionLatencies + 1] = latencyMs

        for actionIndex = 1, ACTIONS_PER_TURN do
            local proposed = sequence[actionIndex] or {type = "skip", unit = {row = 1, col = 1}}
            local resolved, replaced, replacementReason = normalizeActionForState(ai, state, currentPlayer, proposed)
            if replaced then
                actionReplacements = actionReplacements + 1
                incrementCount(replacementReasonCounts, replacementReason or "unknown", 1)
            end

            local beforeSignature = ai:buildActionSequenceSignature({resolved})
            local actingUnit = nil
            local actingUnitName = nil
            if resolved and resolved.type == "skip" then
                actingUnitName = "SKIP_SLOT"
            elseif resolved and resolved.type == "supply_deploy" then
                actingUnitName = resolved.unitName
                if (not actingUnitName) and state.supply and state.supply[currentPlayer] and resolved.unitIndex then
                    local supplyUnit = state.supply[currentPlayer][resolved.unitIndex]
                    actingUnitName = supplyUnit and supplyUnit.name or nil
                end
            elseif resolved and resolved.unit and resolved.unit.row and resolved.unit.col then
                actingUnit = findUnitAt(state, resolved.unit.row, resolved.unit.col)
                actingUnitName = actingUnit and actingUnit.name or nil
            end
            if resolved then
                recordUnitAction(currentPlayer, actingUnitName, resolved.type or "unknown")
            end

            state, actionInteraction = applyActionToState(ai, state, resolved, currentPlayer)
            stateRef.state = state

            if actionInteraction then
                turnInteraction = true
            end

            if not state.commandHubs[opponent] then
                winner = currentPlayer
                outcome = "win"
                reason = "commandant_destroyed"
                break
            end
            if not playerHasUnitsOrSupply(state, opponent) then
                winner = currentPlayer
                outcome = "win"
                reason = "opponent_no_units_or_supply"
                break
            end

            -- Safety guard: prevent action application stalls from looping forever.
            if resolved.type ~= "skip" and ai:buildActionSequenceSignature({resolved}) == beforeSignature then
                -- no-op by design, signature call is used only to force deterministic formatting path
            end
        end

        if outcome == "win" then
            break
        end

        if turnInteraction then
            interactionCounter = 0
        else
            if round >= DRAW_START_TURN then
                interactionCounter = interactionCounter + 1
            end
        end

        state.turnsWithoutDamage = interactionCounter
        if round >= DRAW_START_TURN and interactionCounter >= DRAW_LIMIT then
            outcome = "draw"
            reason = "no_interaction_limit"
            winner = nil
            break
        end

        playerTurns = playerTurns + 1
        if round >= opts.maxRounds and currentPlayer == 2 then
            outcome = "draw"
            reason = "max_round_cap"
            winner = nil
            break
        end

        if currentPlayer == 1 then
            currentPlayer = 2
        else
            currentPlayer = 1
            round = round + 1
        end
    end

    local matchTurns = round
    local latencyMedian = percentile(decisionLatencies, 0.5)
    local latencyP95 = percentile(decisionLatencies, 0.95)

    return {
        matchIndex = matchIndex,
        seed = matchSeed,
        outcome = outcome,
        winner = winner,
        reason = reason,
        rounds = matchTurns,
        playerTurns = playerTurns,
        replacements = actionReplacements,
        replacementReasonCounts = replacementReasonCounts,
        actionTypeCounts = actionTypeCounts,
        actionTypeCountsByPlayer = actionTypeCountsByPlayer,
        unitUsageByPlayer = unitUsageByPlayer,
        decisionCount = #decisionLatencies,
        latency = {
            medianMs = latencyMedian,
            p95Ms = latencyP95,
            samples = decisionLatencies
        }
    }
end

local function buildReport(opts, aggregate)
    return table.concat({
        "# AI Strength Self-Play Report",
        "",
        "- Generated: " .. os.date("%Y-%m-%d %H:%M:%S"),
        "- Matches: " .. tostring(aggregate.matches),
        "- Seed: " .. tostring(opts.seed),
        "- Max rounds per match: " .. tostring(opts.maxRounds),
        "- Player 1 reference: `" .. tostring(opts.p1Ref) .. "`",
        "- Player 2 reference: `" .. tostring(opts.p2Ref) .. "`",
        string.format("- Decision budget target (ms): %s", tostring(PERFORMANCE_RULES.DECISION_BUDGET_MS or 500)),
        "",
        "## Summary",
        "",
        string.format("- Player 1 wins: `%d` (%.2f%%)", aggregate.wins[1], (aggregate.wins[1] / aggregate.matches) * 100),
        string.format("- Player 2 wins: `%d` (%.2f%%)", aggregate.wins[2], (aggregate.wins[2] / aggregate.matches) * 100),
        string.format("- Draws: `%d` (%.2f%%)", aggregate.draws, (aggregate.draws / aggregate.matches) * 100),
        string.format("- Avg rounds: `%.2f`", aggregate.avgRounds),
        string.format("- Decision latency median (ms): `%.3f`", aggregate.decisionLatencyMedian),
        string.format("- Decision latency p95 (ms): `%.3f`", aggregate.decisionLatencyP95),
        string.format("- Action replacements (invalid/skip sanitized): `%d`", aggregate.totalReplacements),
        "",
        "## Outcome Reasons",
        "",
        table.concat(aggregate.reasonLines, "\n"),
        "",
        "## Replacement Reasons",
        "",
        (#aggregate.replacementReasonLines > 0 and table.concat(aggregate.replacementReasonLines, "\n") or "- none"),
        "",
        "## Action Type Usage",
        "",
        (#aggregate.actionTypeLines > 0 and table.concat(aggregate.actionTypeLines, "\n") or "- none"),
        "",
        "## Unit Usecase Stats",
        "",
        (#aggregate.unitUsageLines > 0 and table.concat(aggregate.unitUsageLines, "\n") or "- none"),
        "",
        "## Match Rows",
        "",
        table.concat(aggregate.matchLines, "\n")
    }, "\n")
end

local function evaluate(opts)
    local aggregate = {
        matches = opts.matches,
        wins = {[1] = 0, [2] = 0},
        draws = 0,
        roundsSum = 0,
        totalReplacements = 0,
        reasonCounts = {},
        reasonLines = {},
        replacementReasonLines = {},
        actionTypeLines = {},
        unitUsageLines = {},
        matchLines = {},
        allDecisionLatencies = {},
        replacementReasonCounts = {},
        actionTypeCounts = {},
        actionTypeCountsByPlayer = {[1] = {}, [2] = {}},
        unitUsageByPlayer = {[1] = {}, [2] = {}},
        unitUsageTotal = {}
    }

    for matchIndex = 1, opts.matches do
        local result = runMatch(matchIndex, opts)
        if result.outcome == "win" and result.winner then
            aggregate.wins[result.winner] = (aggregate.wins[result.winner] or 0) + 1
        else
            aggregate.draws = aggregate.draws + 1
        end

        aggregate.roundsSum = aggregate.roundsSum + result.rounds
        aggregate.totalReplacements = aggregate.totalReplacements + (result.replacements or 0)
        aggregate.reasonCounts[result.reason] = (aggregate.reasonCounts[result.reason] or 0) + 1
        for reason, count in pairs(result.replacementReasonCounts or {}) do
            incrementCount(aggregate.replacementReasonCounts, reason, count)
        end

        for actionType, count in pairs(result.actionTypeCounts or {}) do
            incrementCount(aggregate.actionTypeCounts, actionType, count)
        end
        for player = 1, 2 do
            local byPlayer = result.actionTypeCountsByPlayer and result.actionTypeCountsByPlayer[player] or {}
            for actionType, count in pairs(byPlayer or {}) do
                incrementCount(aggregate.actionTypeCountsByPlayer[player], actionType, count)
            end
        end

        for player = 1, 2 do
            local usage = result.unitUsageByPlayer and result.unitUsageByPlayer[player] or {}
            for unitName, unitStats in pairs(usage or {}) do
                local aggPlayerUsage = ensureTable(aggregate.unitUsageByPlayer[player], unitName)
                local aggTotalUsage = ensureTable(aggregate.unitUsageTotal, unitName)
                for statName, statValue in pairs(unitStats or {}) do
                    incrementCount(aggPlayerUsage, statName, statValue)
                    incrementCount(aggTotalUsage, statName, statValue)
                end
            end
        end

        for _, latency in ipairs(result.latency.samples or {}) do
            aggregate.allDecisionLatencies[#aggregate.allDecisionLatencies + 1] = latency
        end

        aggregate.matchLines[#aggregate.matchLines + 1] = string.format(
            "- Match %d | seed=%d | outcome=%s%s | rounds=%d | replacements=%d | latency_p95=%.3fms",
            result.matchIndex,
            result.seed,
            result.outcome,
            result.winner and ("(P" .. tostring(result.winner) .. ")") or "",
            result.rounds,
            result.replacements or 0,
            result.latency.p95Ms or 0
        )

        if opts.verbose then
            print(string.format(
                "[%02d/%02d] outcome=%s%s reason=%s rounds=%d replacements=%d p95=%.3fms",
                matchIndex,
                opts.matches,
                result.outcome,
                result.winner and ("(P" .. tostring(result.winner) .. ")") or "",
                tostring(result.reason),
                result.rounds,
                result.replacements or 0,
                result.latency.p95Ms or 0
            ))
        end
    end

    aggregate.avgRounds = aggregate.roundsSum / math.max(1, opts.matches)
    aggregate.decisionLatencyMedian = percentile(aggregate.allDecisionLatencies, 0.5)
    aggregate.decisionLatencyP95 = percentile(aggregate.allDecisionLatencies, 0.95)

    local reasonPairs = {}
    for reason, count in pairs(aggregate.reasonCounts) do
        reasonPairs[#reasonPairs + 1] = {reason = reason, count = count}
    end
    table.sort(reasonPairs, function(a, b)
        if a.count == b.count then
            return a.reason < b.reason
        end
        return a.count > b.count
    end)

    for _, entry in ipairs(reasonPairs) do
        aggregate.reasonLines[#aggregate.reasonLines + 1] = string.format("- `%s`: %d", tostring(entry.reason), entry.count)
    end

    local replacementPairs = {}
    for reason, count in pairs(aggregate.replacementReasonCounts) do
        replacementPairs[#replacementPairs + 1] = {reason = reason, count = count}
    end
    table.sort(replacementPairs, function(a, b)
        if a.count == b.count then
            return a.reason < b.reason
        end
        return a.count > b.count
    end)
    for _, entry in ipairs(replacementPairs) do
        aggregate.replacementReasonLines[#aggregate.replacementReasonLines + 1] = string.format("- `%s`: %d", tostring(entry.reason), entry.count)
    end

    local actionTypePairs = {}
    for actionType, count in pairs(aggregate.actionTypeCounts) do
        actionTypePairs[#actionTypePairs + 1] = {actionType = actionType, count = count}
    end
    table.sort(actionTypePairs, function(a, b)
        if a.count == b.count then
            return a.actionType < b.actionType
        end
        return a.count > b.count
    end)
    for _, entry in ipairs(actionTypePairs) do
        local p1 = aggregate.actionTypeCountsByPlayer[1][entry.actionType] or 0
        local p2 = aggregate.actionTypeCountsByPlayer[2][entry.actionType] or 0
        aggregate.actionTypeLines[#aggregate.actionTypeLines + 1] = string.format(
            "- `%s`: total=%d | P1=%d | P2=%d",
            tostring(entry.actionType),
            entry.count,
            p1,
            p2
        )
    end

    local unitUsageRows = {}
    for unitName, totalStats in pairs(aggregate.unitUsageTotal) do
        unitUsageRows[#unitUsageRows + 1] = {
            unitName = unitName,
            total = totalStats.total or 0
        }
    end
    table.sort(unitUsageRows, function(a, b)
        if a.total == b.total then
            return a.unitName < b.unitName
        end
        return a.total > b.total
    end)

    local actionTypes = {"supply_deploy", "move", "attack", "repair", "skip"}
    for _, row in ipairs(unitUsageRows) do
        local unitName = row.unitName
        local totalStats = aggregate.unitUsageTotal[unitName] or {}
        local p1Stats = aggregate.unitUsageByPlayer[1][unitName] or {}
        local p2Stats = aggregate.unitUsageByPlayer[2][unitName] or {}
        local parts = {
            string.format("- `%s`: total=%d", tostring(unitName), row.total),
            string.format("P1=%d", p1Stats.total or 0),
            string.format("P2=%d", p2Stats.total or 0)
        }
        for _, actionType in ipairs(actionTypes) do
            local actionTotal = totalStats[actionType] or 0
            if actionTotal > 0 then
                parts[#parts + 1] = string.format("%s=%d", actionType, actionTotal)
            end
        end
        aggregate.unitUsageLines[#aggregate.unitUsageLines + 1] = table.concat(parts, " | ")
    end

    return aggregate
end

local opts = parseArgs(arg or {})
local aggregate = evaluate(opts)
local report = buildReport(opts, aggregate)

local reportFile = io.open(opts.reportPath, "w")
if reportFile then
    reportFile:write(report)
    reportFile:close()
end

print(report)
