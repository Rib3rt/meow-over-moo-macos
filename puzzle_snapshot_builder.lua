local snapshotBuilder = {}

local function cloneValue(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    for key, nested in pairs(value) do
        out[cloneValue(key, seen)] = cloneValue(nested, seen)
    end
    return out
end

local function asWholeNumber(value, fallback)
    local num = tonumber(value)
    if not num then
        return fallback
    end
    return math.floor(num)
end

local function normalizePlayer(value, fallback)
    local player = asWholeNumber(value, fallback)
    if player ~= 1 and player ~= 2 then
        return fallback
    end
    return player
end

local function normalizeTurnOrder(value)
    local normalized = {}
    if type(value) == "table" then
        for _, player in ipairs(value) do
            local parsed = normalizePlayer(player, nil)
            if parsed then
                normalized[#normalized + 1] = parsed
            end
        end
    end
    if #normalized == 0 then
        return {1, 2}
    end
    return normalized
end

local function normalizeFactionAssignments(value)
    local assignments = {}
    if type(value) ~= "table" then
        return assignments
    end
    for key, assignment in pairs(value) do
        local player = normalizePlayer(key, nil)
        if player and assignment ~= nil then
            assignments[player] = assignment
        end
    end
    return assignments
end

local function normalizeSupplies(value)
    local supplies = {
        [1] = {},
        [2] = {}
    }
    if type(value) ~= "table" then
        return supplies
    end
    for player = 1, 2 do
        local source = value[player]
        if type(source) == "table" then
            for index, unitName in ipairs(source) do
                if unitName ~= nil then
                    supplies[player][index] = unitName
                end
            end
        end
    end
    return supplies
end

local function buildIntegritySignature(boardUnits, playerSupplies)
    local signature = {
        boardUnitTotal = 0,
        boardByPlayer = { [0] = 0, [1] = 0, [2] = 0 },
        supplyByPlayer = { [1] = 0, [2] = 0 },
        commandants = { [1] = 0, [2] = 0 }
    }

    for _, entry in ipairs(boardUnits) do
        local player = normalizePlayer(entry.player, 0) or 0
        signature.boardUnitTotal = signature.boardUnitTotal + 1
        signature.boardByPlayer[player] = (signature.boardByPlayer[player] or 0) + 1
        if tostring(entry.name or "") == "Commandant" and (player == 1 or player == 2) then
            signature.commandants[player] = (signature.commandants[player] or 0) + 1
        end
    end

    for player = 1, 2 do
        signature.supplyByPlayer[player] = #(playerSupplies[player] or {})
    end

    return signature
end

function snapshotBuilder.build(config)
    if type(config) ~= "table" then
        error("snapshotBuilder.build expects a table config")
    end

    local boardUnits = {}
    local commandHubPositions = {}
    for _, rawUnit in ipairs(config.units or {}) do
        local name = tostring(rawUnit.name or "")
        local player = normalizePlayer(rawUnit.player, nil)
        local row = asWholeNumber(rawUnit.row, nil)
        local col = asWholeNumber(rawUnit.col, nil)
        if name ~= "" and player and row and col then
            local unitEntry = {
                name = name,
                player = player,
                row = row,
                col = col,
                hasActed = false,
                turnActions = {}
            }
            if rawUnit.currentHp ~= nil then
                unitEntry.currentHp = tonumber(rawUnit.currentHp) or rawUnit.currentHp
            end
            if rawUnit.startingHp ~= nil then
                unitEntry.startingHp = tonumber(rawUnit.startingHp) or rawUnit.startingHp
            end
            boardUnits[#boardUnits + 1] = unitEntry
            if name == "Commandant" then
                commandHubPositions[player] = { row = row, col = col }
            end
        end
    end

    if not commandHubPositions[2] then
        error("snapshotBuilder.build requires one Red Commandant")
    end

    if commandHubPositions[1] then
        error("snapshotBuilder.build does not allow Blue Commandant in scenario snapshots")
    end

    local turnOrder = normalizeTurnOrder(config.turnOrder)
    local factionAssignments = normalizeFactionAssignments(config.factionAssignments)
    local playerSupplies = normalizeSupplies(config.playerSupplies or config.supplies)
    local integritySignature = buildIntegritySignature(boardUnits, playerSupplies)
    local currentTurn = math.max(1, asWholeNumber(config.currentTurn, 1))
    local currentPlayer = normalizePlayer(config.currentPlayer, 1)
    local currentTurnActions = math.max(0, asWholeNumber(config.currentTurnActions, 0))
    local maxActionsPerTurn = math.max(1, asWholeNumber(config.maxActionsPerTurn, 2))
    local seed = asWholeNumber(config.logicRngSeed, 12001 + #boardUnits)

    return {
        version = asWholeNumber(config.version, 4),
        currentPhase = tostring(config.currentPhase or "turn"),
        currentTurnPhase = tostring(config.currentTurnPhase or "actions"),
        currentTurn = currentTurn,
        currentPlayer = currentPlayer,
        turnOrder = turnOrder,
        factionAssignments = factionAssignments,
        winner = nil,
        maxActionsPerTurn = maxActionsPerTurn,
        currentTurnActions = currentTurnActions,
        hasDeployedThisTurn = config.hasDeployedThisTurn ~= false,
        commandHubPositions = cloneValue(commandHubPositions),
        tempCommandHubPosition = {},
        commandHubPlacementReady = true,
        initialDeployment = {
            requiredDeployments = 0,
            completedDeployments = 0,
            selectedUnitIndex = nil,
            availableCells = {}
        },
        turnsWithoutDamage = 0,
        turnHadInteraction = false,
        drawGame = false,
        noMoreUnitsGameOver = false,
        logicRngSeed = seed,
        logicRngState = asWholeNumber(config.logicRngState, seed),
        neutralBuildings = cloneValue(config.neutralBuildings or {}),
        neutralBuildingsPlaced = asWholeNumber(config.neutralBuildingsPlaced, 0),
        targetRows = cloneValue(config.targetRows or {3, 4, 5, 6}),
        usedRows = cloneValue(config.usedRows or {}),
        actionsPhaseSupplySelection = nil,
        playerSupplies = cloneValue(playerSupplies),
        boardUnits = cloneValue(boardUnits),
        integritySignature = integritySignature,
        gridSetupComplete = {
            [1] = true,
            [2] = true
        }
    }
end

return snapshotBuilder
