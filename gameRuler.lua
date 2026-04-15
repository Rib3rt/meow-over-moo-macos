local gameRuler = {}
gameRuler.__index = gameRuler

local unitsInfo = require("unitsInfo")
local ConfirmDialog = require("confirmDialog")
local soundCache = require("soundCache")
local aiConfig = require("ai_config")
local logger = require("logger")
local randomGenerator = require("randomGenerator")
local debugConsoleLog = require("debug_console_log")

local AI_PARAMS = (aiConfig and aiConfig.AI_PARAMS) or {}
local RULE_CONTRACT = AI_PARAMS.RULE_CONTRACT or {}
local SETUP_RULES = RULE_CONTRACT.SETUP or {}
local OBSTACLE_RULES = SETUP_RULES.OBSTACLES or {}
local COMMANDANT_ZONE_RULES = SETUP_RULES.COMMANDANT_ZONE or {}
local INITIAL_DEPLOY_RULES = SETUP_RULES.INITIAL_DEPLOY or {}
local TURN_RULES = RULE_CONTRACT.TURN or {}
local ACTION_RULES = RULE_CONTRACT.ACTIONS or {}
local DRAW_RULES = RULE_CONTRACT.DRAW or {}
local DEFAULT_LAST_GAME_LOG_PATH = "LastGameLog.txt"
local DRAW_AT_TURN_PROTECTION_TOKEN = "__LAST_GAME_LOG_DRAW_TOKEN__"

--------------------------------------------------
-- PHASE DEFINITIONS AND TRANSITIONS
--------------------------------------------------

-- Define all possible game phases and their valid transitions
local PHASES = {
    -- Main game phases
    SETUP = "setup",
    DEPLOY1 = "deploy1",
    DEPLOY1_UNITS = "deploy1_units", -- New phase for Player 1's initial unit deployment
    DEPLOY2 = "deploy2",
    DEPLOY2_UNITS = "deploy2_units", -- New phase for Player 2's initial unit deployment
    TURN = "turn",
    GAME_OVER = "gameOver"
}

-- Define all turn sub-phases and their transitions
local TURN_PHASES = {
    ACTIONS = "actions",
    COMMAND_HUB = "commandHub",
    END_TURN = "endTurn"
}

-- Phase transitions define the flow of the game
local PHASE_TRANSITIONS = {
    [PHASES.SETUP] = PHASES.DEPLOY1,
    [PHASES.DEPLOY1] = PHASES.DEPLOY1_UNITS, -- Commandant → Deploy Units
    [PHASES.DEPLOY1_UNITS] = PHASES.DEPLOY2, -- After deployment → Player 2's hub
    [PHASES.DEPLOY2] = PHASES.DEPLOY2_UNITS, -- Commandant → Deploy Units
    [PHASES.DEPLOY2_UNITS] = PHASES.TURN,    -- After deployment → Main game
    [PHASES.TURN] = PHASES.GAME_OVER
}

-- Turn phase transitions define the flow within a turn
local TURN_PHASE_TRANSITIONS = {
    [TURN_PHASES.COMMAND_HUB] = TURN_PHASES.ACTIONS,  -- Commandant → Actions
    [TURN_PHASES.ACTIONS] = nil,  -- Actions has no automatic transition (like old version)
}

-- Define which actions are allowed in each phase
local ALLOWED_ACTIONS = {
    [PHASES.SETUP] = {
        placeNeutralBuilding = true,
        placeAllNeutralBuildings = true
    },
    [PHASES.DEPLOY1] = {
        placeCommandHub = true,
        confirmCommandHub = true
    },
    [PHASES.DEPLOY1_UNITS] = {
        selectSupplyUnit = true,
        deployUnitNearHub = true,
        confirmDeployment = true
    },
    [PHASES.DEPLOY2] = {
        placeCommandHub = true,
        confirmCommandHub = true
    },
    [PHASES.DEPLOY2_UNITS] = {
        selectSupplyUnit = true,
        deployUnitNearHub = true,
        confirmDeployment = true
    },
    [PHASES.TURN] = {
        -- Turn phases have their own allowed actions
    },
    [PHASES.GAME_OVER] = {
        newGame = true
    }
}

-- Define allowed actions for each turn phase
local TURN_PHASE_ACTIONS = {
    [TURN_PHASES.ACTIONS] = {
        move = true,
        attack = true,
        repair = true,
        deployUnit = true,
        selectSupplyUnit = true,
        endActions = true,
    },
    [TURN_PHASES.COMMAND_HUB] = {
        deployFromCommandHub = true,
        startCommandHubDefense = true,
        endCommandHub = true
    },
    [TURN_PHASES.END_TURN] = {
        confirmEndTurn = true
    }
}

-- Phase descriptions and instructions for UI
local PHASE_INFO = {
    [PHASES.SETUP] = {
        desc = "Setup Phase",
        instructions = function(self) 
            local requiredObstacles = OBSTACLE_RULES.COUNT or 4
            return "Scatter " .. requiredObstacles .. " Rocks on the field.\n"
        end
    },
    [PHASES.DEPLOY1] = {
        desc = "Commandant Deployment - Player 1",
        instructions = "Choose where to place your Commandant."
    },
    [PHASES.DEPLOY1_UNITS] = {
        desc = "Initial Deployment - Player 1",
        instructions = function(self) 
            local remaining = self:getRemainingRequiredDeployments()
            if remaining <= 0 then
                return "Initial Deployment phase completed!\n"
            else
                return "Deploy a unit close to your Commandant."
            end
        end
    },
    [PHASES.DEPLOY2] = {
        desc = "Commandant Deployment - Player 2",
        instructions = "Choose where to place your Commandant."
    },
    [PHASES.DEPLOY2_UNITS] = {
        desc = "Initial Deployment - Player 2",
        instructions = function(self)
            local remaining = self:getRemainingRequiredDeployments()
            if remaining <= 0 then
                return "Initial Deployment phase completed!\n"
            else
                return "Deploy a unit close to your Commandant."
            end
        end
    },
    [PHASES.TURN] = {
        -- Turn phases have their own descriptions
    },
    [PHASES.GAME_OVER] = {
        desc = "Game Over",
        instructions = function(self)
            if self.winner == 0 then
                return "The battle ends in a draw."
            end

            local winnerId = tonumber(self.winner)
            if winnerId and GAME and GAME.getFactionControllerNickname then
                local nickname = GAME.getFactionControllerNickname(winnerId)
                if nickname and nickname ~= "" then
                    return tostring(nickname) .. " wins the battle!"
                end
            end

            return "Player " .. (self.winner or "?") .. " wins the battle!"
        end
    }
}

function gameRuler:getActionAnimationDelay(actionType)
    if actionType == "move" then
        return 0.35
    elseif actionType == "attack" then
        return 0.45
    elseif actionType == "repair" then
        return 0.4
    elseif actionType == "supply" or actionType == "supply_deploy" then
        return 0.5
    end

    return 0.4
end

local TURN_PHASE_INFO = {
    [TURN_PHASES.COMMAND_HUB] = {
        desc = "Commandant Defense Phase",
        instructions = function(self) 
            if self.commandHubDefenseActive then
                return "Commandant's defense phase."
            end
        end
    },
    [TURN_PHASES.ACTIONS] = {
        desc = "Actions Phase", 
        instructions = function(self) 
            if self:areActionsComplete() then
                return "All actions done!\nEnd your turn."
            else
                local possibleActions = self:calculatePossibleActions()
                local maxActions = self.maxActionsPerTurn or GAME.CONSTANTS.MAX_ACTIONS_PER_TURN or 2
                local availableActions = math.min(possibleActions, maxActions)
                local currentActions = self.currentTurnActions or 0
                local remainingActions = math.max(0, maxActions - currentActions)

                local actionsList = self:getAvailableActionsList()
                return "Actions to go: " .. remainingActions .. "\n" .. actionsList
            end
        end
    },
    [TURN_PHASES.END_TURN] = {
        desc = "End of Turn",
        instructions = function(self)
            return "Press to start next turn"
        end
    }
}

local function getWallClockTimestamp()
    if type(os) == "table" and type(os.date) == "function" then
        local ok, formatted = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if ok and formatted then
            return formatted
        end
    end

    if love and love.timer and type(love.timer.getTime) == "function" then
        return string.format("t=%.3fs", love.timer.getTime())
    end

    return "unknown_time"
end

local function sanitizeSingleLine(text)
    local value = tostring(text or "")
    value = value:gsub("[\r\n]+", " ")
    value = value:gsub("%s+", " ")
    value = value:gsub("^%s+", "")
    value = value:gsub("%s+$", "")
    return value
end

local function parsePlayerId(playerValue)
    if type(playerValue) == "number" then
        if playerValue >= 0 then
            return tostring(math.floor(playerValue))
        end
        return nil
    end

    if type(playerValue) == "string" then
        local parsed = playerValue:match("^%s*P?(%d+)%s*$")
        if parsed then
            return parsed
        end
    end

    return nil
end

function gameRuler:buildLastGameLogUnitAbbrevMap()
    local abbrevMap = {}
    local allInfo = unitsInfo:getAllUnitInfo() or {}
    for _, info in pairs(allInfo) do
        if info and info.shortName and info.name then
            abbrevMap[tostring(info.shortName)] = tostring(info.name)
        end
    end

    -- Existing logs can emit both CH and CM for command hub actions.
    abbrevMap.CM = "Commandant"
    abbrevMap.CH = "Commandant"

    local keys = {}
    for key, _ in pairs(abbrevMap) do
        keys[#keys + 1] = key
    end

    table.sort(keys, function(left, right)
        if #left ~= #right then
            return #left > #right
        end
        return left < right
    end)

    return abbrevMap, keys
end

function gameRuler:resolveLastGameLogPath(params)
    local configured = params and params.lastGameLogPath
    if configured and tostring(configured) ~= "" then
        return tostring(configured)
    end

    if love and love.filesystem and type(love.filesystem.getSaveDirectory) == "function" then
        local okSave, saveDir = pcall(love.filesystem.getSaveDirectory)
        if okSave and type(saveDir) == "string" and saveDir ~= "" then
            local normalized = saveDir:gsub("[/\\]+$", "")
            return normalized .. "/" .. DEFAULT_LAST_GAME_LOG_PATH
        end
    end

    return DEFAULT_LAST_GAME_LOG_PATH
end

function gameRuler:warnLastGameLogFailure(context, err)
    if self.suppressLastGameLogWarnings == true then
        return
    end

    if self.lastGameLogWarned then
        return
    end

    self.lastGameLogWarned = true
    logger.warn("GAMEPLAY", string.format(
        "[LastGameLog] %s failed for '%s': %s",
        tostring(context or "write"),
        tostring(self.lastGameLogPath or DEFAULT_LAST_GAME_LOG_PATH),
        tostring(err or "unknown error")
    ))
end

function gameRuler:expandLogUnitsToFullNames(text)
    local expanded = sanitizeSingleLine(text)

    -- Protect the draw message phrase so "AT" isn't treated as Artillery.
    expanded = expanded:gsub("AT TURN", DRAW_AT_TURN_PROTECTION_TOKEN)

    local keys = self.lastGameLogUnitAbbrevKeys or {}
    local map = self.lastGameLogUnitAbbrevMap or {}
    for _, abbrev in ipairs(keys) do
        local fullName = map[abbrev]
        if fullName and fullName ~= "" then
            local pattern = "%f[%w]" .. abbrev .. "%f[%W]"
            expanded = expanded:gsub(pattern, fullName)
        end
    end

    expanded = expanded:gsub(DRAW_AT_TURN_PROTECTION_TOKEN, "AT TURN")
    return expanded
end

function gameRuler:formatLastGameLogLine(rawEntry, playerOverride)
    local message = sanitizeSingleLine(rawEntry)
    local playerId = parsePlayerId(playerOverride)

    local prefixedPlayer, strippedMessage = message:match("^P(%d+)%s+(.+)$")
    if prefixedPlayer and strippedMessage then
        if not playerId then
            playerId = prefixedPlayer
        end
        message = strippedMessage
    end

    message = self:expandLogUnitsToFullNames(message)
    if message == "" then
        message = "-"
    end

    local timestamp = getWallClockTimestamp()
    local turn = tostring(self.currentTurn or 0)
    local phase = tostring(self.currentPhase or "unknown")
    local turnPhase = tostring(self.currentTurnPhase or "-")
    local playerTag = playerId or "-"

    return string.format(
        "[%s] [T%s] [%s/%s] [P%s] %s",
        timestamp,
        turn,
        phase,
        turnPhase,
        playerTag,
        message
    )
end

function gameRuler:writeLastGameHeader(reason, fileHandle)
    local lines = {
        "=== Last Game Log ===",
        "Started: " .. getWallClockTimestamp(),
        "Reason: " .. tostring(reason or "new_game"),
        string.rep("-", 72)
    }

    local payload = table.concat(lines, "\n") .. "\n"
    if fileHandle then
        fileHandle:write(payload)
        return true
    end

    if self.lastGameLogUseLoveFilesystem and love and love.filesystem and type(love.filesystem.write) == "function" then
        local okWrite, errWrite = love.filesystem.write(self.lastGameLogVirtualPath or DEFAULT_LAST_GAME_LOG_PATH, payload)
        if not okWrite then
            self:warnLastGameLogFailure("header_write", errWrite)
            self.lastGameLogWriteDisabled = true
            return false
        end
        return true
    end

    local file, err = io.open(self.lastGameLogPath, "w")
    if not file then
        self:warnLastGameLogFailure("header_open", err)
        self.lastGameLogWriteDisabled = true
        return false
    end

    file:write(payload)
    file:close()
    return true
end

function gameRuler:resetLastGameLogFile(reason)
    self.lastGameLogWriteDisabled = false
    self.lastGameLogWarned = false

    if self.lastGameLogUseLoveFilesystem and love and love.filesystem and type(love.filesystem.write) == "function" then
        local ok = self:writeLastGameHeader(reason or "new_game")
        if not ok then
            self.lastGameLogWriteDisabled = true
        end
        return ok
    end

    local file, err = io.open(self.lastGameLogPath, "w")
    if not file then
        self.lastGameLogWriteDisabled = true
        self:warnLastGameLogFailure("reset_open", err)
        return false
    end

    self:writeLastGameHeader(reason or "new_game", file)
    file:close()
    return true
end

function gameRuler:appendLastGameLogLine(rawEntry, playerOverride)
    if self.lastGameLogWriteDisabled then
        return false
    end

    local line = self:formatLastGameLogLine(rawEntry, playerOverride)

    if self.lastGameLogUseLoveFilesystem and love and love.filesystem and type(love.filesystem.append) == "function" then
        local okAppend, errAppend = love.filesystem.append(self.lastGameLogVirtualPath or DEFAULT_LAST_GAME_LOG_PATH, line .. "\n")
        if not okAppend then
            self.lastGameLogWriteDisabled = true
            self:warnLastGameLogFailure("append_write", errAppend)
            return false
        end
        return true
    end

    local file, err = io.open(self.lastGameLogPath, "a")
    if not file then
        self.lastGameLogWriteDisabled = true
        self:warnLastGameLogFailure("append_open", err)
        return false
    end

    file:write(line .. "\n")
    file:close()
    return true
end

local function normalizeSeed(seed)
    local n = tonumber(seed) or 1
    if n < 0 then
        n = -n
    end
    return math.floor(n) % 2147483647
end

function gameRuler:initializeLogicRng(seed)
    local normalized = normalizeSeed(seed)
    if normalized == 0 then
        normalized = 1
    end
    self.logicRngSeed = normalized
    self.logicRngState = normalized
end

function gameRuler:nextLogicRandom()
    -- Deterministic Park-Miller LCG for gameplay state mutations.
    local state = self.logicRngState or 1
    state = (state * 16807) % 2147483647
    self.logicRngState = state
    return state / 2147483647
end

function gameRuler:logicRandomInt(minValue, maxValue)
    local minV = math.floor(tonumber(minValue) or 1)
    local maxV = math.floor(tonumber(maxValue) or minV)
    if maxV < minV then
        minV, maxV = maxV, minV
    end

    local roll = self:nextLogicRandom()
    return minV + math.floor(roll * (maxV - minV + 1))
end

local function copySerializable(value, seen)
    local valueType = type(value)
    if valueType == "nil" or valueType == "number" or valueType == "boolean" or valueType == "string" then
        return value
    end

    if valueType ~= "table" then
        return nil
    end

    seen = seen or {}
    if seen[value] then
        return nil
    end
    seen[value] = true

    local copy = {}
    for key, child in pairs(value) do
        local copiedKey = copySerializable(key, seen)
        local copiedValue = copySerializable(child, seen)
        if copiedKey ~= nil and copiedValue ~= nil then
            copy[copiedKey] = copiedValue
        end
    end

    seen[value] = nil
    return copy
end

--------------------------------------------------
-- INSTANCE CREATION
--------------------------------------------------

function gameRuler.new(params)
    local self = setmetatable({}, gameRuler)
    params = params or {}

    -- Add game timer properties
    self.gameTimer = {
        startTime = love.timer.getTime(),
        endTime = nil,
        isRunning = true,
        totalGameTime = 0,
        lastTurnChangeTime = love.timer.getTime(),
        playerTime = {
            [1] = 0,  -- Time spent by player 1
            [2] = 0   -- Time spent by player 2
        },
        currentPlayerStartTime = love.timer.getTime()
    }

    local assignments = GAME.CURRENT.FACTION_ASSIGNMENTS or {}
    self.factionAssignments = {
        [1] = assignments[1],
        [2] = assignments[2]
    }

    self.turnOrder = params.turnOrder or GAME.CURRENT.TURN_ORDER or {1, 2}

    -- Core game state
    self.currentPhase = params.currentPhase or PHASES.SETUP
    self.currentTurnPhase = params.currentTurnPhase or TURN_PHASES.ACTIONS
    self.currentPlayer = params.currentPlayer or self.turnOrder[1]
    self.currentTurn = params.currentTurn or 0
    self.currentGrid = params.currentGrid or nil
    self.winner = nil
    self.lastVictoryReason = nil

    local fallbackSeed = GAME.CURRENT.SEED or randomGenerator.getSeed()
    if not fallbackSeed and love and love.timer and love.timer.getTime then
        fallbackSeed = math.floor(love.timer.getTime() * 1000000)
    end
    self:initializeLogicRng(params.logicSeed or fallbackSeed or 1)

    -- Faction constants
    self.player1Faction = 1
    self.player2Faction = 2
    self.aiPlayerNumber = GAME.getAIFactionId()

    -- Action tracking
    self.maxActionsPerTurn = TURN_RULES.ACTIONS_PER_TURN or GAME.CONSTANTS.MAX_ACTIONS_PER_TURN
    self.currentTurnActions = 0

    -- Unit tracking
    self.currentUnit = nil
    self.currentTarget = nil

    -- Rocks
    self.totalNeutralBuildings = OBSTACLE_RULES.COUNT or 4
    self.neutralBuildings = {}

    -- Commandant placement zones
    self.commandHubsValidPositions = {
        [1] = {
            min = (COMMANDANT_ZONE_RULES[1] and COMMANDANT_ZONE_RULES[1].MIN_ROW) or 1,
            max = (COMMANDANT_ZONE_RULES[1] and COMMANDANT_ZONE_RULES[1].MAX_ROW) or 2
        },
        [2] = {
            min = (COMMANDANT_ZONE_RULES[2] and COMMANDANT_ZONE_RULES[2].MIN_ROW) or 7,
            max = (COMMANDANT_ZONE_RULES[2] and COMMANDANT_ZONE_RULES[2].MAX_ROW) or 8
        }
    }

    -- Initialize turn counter for draw condition
    self.turnsWithoutDamage = 0
    self.turnHadInteraction = false
    self.drawGame = false
    self.onlineDrawOfferPending = false

    -- no more unity Game Over condition
    self.noMoreUnitsGameOver = false

    -- Commandant placement tracking
    self.commandHubPositions = {}
    self.tempCommandHubPosition = {}

    -- Player supplies
    self.playerSupplies = {
        [1] = params.player1Supply or self:createInitialSupply(1),
        [2] = params.player2Supply or self:createInitialSupply(2)
    }
    self.player1Supply = self.playerSupplies[1]
    self.player2Supply = self.playerSupplies[2]

    -- Callback registry for phase changes
    self.phaseCallbacks = {}

    -- Initial deployment tracking
    self.initialDeployment = {
        requiredDeployments = INITIAL_DEPLOY_RULES.COUNT or 1,
        completedDeployments = 0,
        availableCells = {},
        selectedUnitIndex = nil
    }

    self.startAutonomousAiSelection = false

    self.neutralBuildingPlacementInProgress = false

    -- Add scheduler for timed actions
    self.scheduledActions = {}

    -- Game Log
    self.turnLog = {}
    local configuredLastGameLogPath = params and params.lastGameLogPath
    self.lastGameLogHasExplicitPath = configuredLastGameLogPath ~= nil and tostring(configuredLastGameLogPath) ~= ""
    self.lastGameLogVirtualPath = DEFAULT_LAST_GAME_LOG_PATH
    self.lastGameLogUseLoveFilesystem = (not self.lastGameLogHasExplicitPath)
        and love
        and love.filesystem
        and type(love.filesystem.write) == "function"
        and type(love.filesystem.append) == "function"
    self.lastGameLogPath = self:resolveLastGameLogPath(params)
    self.lastGameLogWriteDisabled = false
    self.lastGameLogWarned = false
    self.suppressLastGameLogWarnings = params and params.suppressLastGameLogWarnings == true
    self.lastGameLogUnitAbbrevMap, self.lastGameLogUnitAbbrevKeys = self:buildLastGameLogUnitAbbrevMap()
    logger.info("GAMEPLAY", string.format(
        "[LastGameLog] path resolved: %s (%s)",
        tostring(self.lastGameLogPath),
        self.lastGameLogUseLoveFilesystem and "love.filesystem" or "io"
    ))
    self:resetLastGameLogFile("new_game")
    if debugConsoleLog and debugConsoleLog.reset then
        debugConsoleLog.reset("new_game")
    end

    self.gameStats = {
        startTime = love.timer.getTime(),
        endTime = nil,
        totalGameTime = 0,
        turns = 0,
        neutralBuildingsDestroyed = 0,

        players = {
            [1] = {
                damageDealt = 0,
                damageTaken = 0,
                unitsDeployed = 0,
                unitsLost = 0,
                unitsDestroyed = 0,
                actionsUsed = 0,
                repairPoints = 0,
                commandHubAttacksSurvived = 0
            },
            [2] = {
                damageDealt = 0,
                damageTaken = 0,
                unitsDeployed = 0,
                unitsLost = 0,
                unitsDestroyed = 0,
                actionsUsed = 0,
                repairPoints = 0,
                commandHubAttacksSurvived = 0
            }
        },

        -- Per unit type stats (dynamically generated from unitsInfo)
        unitStats = {}
    }

    -- Initialize unit stats dynamically from unitsInfo
    local unitNames = unitsInfo:getAllUnitNames()
    for _, unitName in ipairs(unitNames) do
        self.gameStats.unitStats[unitName] = {deployed = 0, lost = 0, kills = 0, damageDealt = 0}
    end

    self.hasDeployedThisTurn = false

    return self
end

function gameRuler:deployUnitInActionsPhase(unitIndex, row, col)
    -- Check if we can deploy (only once per turn)
    if self.hasDeployedThisTurn then
        return false, "Already deployed this turn"
    end

    -- Check if we have actions remaining
    if self:areActionsComplete() then
        return false, "No actions remaining"
    end

    -- Get the current player's supply
    local supply = nil
    if self.currentPlayer == 1 then
        supply = self.player1Supply
    else
        supply = self.player2Supply
    end

    if not supply or #supply == 0 then
        return false, "No units in supply"
    end

    -- Get the selected unit
    local unit = supply[unitIndex]
    if not unit then
        return false, "Invalid unit selection"
    end

    -- Check if the cell is empty
    if not self.currentGrid:isCellEmpty(row, col) then
        return false, "Cell not empty"
    end

    -- Check if the cell is adjacent to Commandant
    local hubPos = self.commandHubPositions[self.currentPlayer]
    if not hubPos then
        return false, "No Commandant found"
    end

    local isAdjacent = (math.abs(row - hubPos.row) + math.abs(col - hubPos.col)) == 1
    if not isAdjacent then
        return false, "Must deploy adjacent to Commandant"
    end

    -- Count global action and mark deployment
    self.currentTurnActions = (self.currentTurnActions or 0) + 1
    self.hasDeployedThisTurn = true
    
    -- Note: Do not recalculate max actions mid-turn as it violates action limit consistency
    

    -- Set player ownership for the unit
    unit.player = self.currentPlayer
    if unit.startingHp then
        unit.currentHp = unit.startingHp
    end

    -- Mark unit as acted (deployed units can't act this turn)
    unit.hasActed = true
    unit.turnActions = {deploy = true}

    -- Create beam effect and pass the unit to place after animation
    self.currentGrid:createBeamEffect(row, col, unit)
    
    -- Play teleport whoosh sound when unit evocation effect starts
    if self.currentGrid and self.currentGrid.playTeleportSound then
        self.currentGrid:playTeleportSound()
    end

    -- Remove the unit from supply
    table.remove(supply, unitIndex)

    -- Add log entry
    self:addLogEntry(self.currentPlayer,
                "deploy " .. unit.name .. " in",
                row,
                col
    )

    -- Update stats
    self.gameStats.players[self.currentPlayer].unitsDeployed = 
        self.gameStats.players[self.currentPlayer].unitsDeployed + 1

    if self.gameStats.unitStats[unit.name] then
        self.gameStats.unitStats[unit.name].deployed = 
            self.gameStats.unitStats[unit.name].deployed + 1
    end

    return true
end

-- Coordinate conversion function
function gameRuler:gridToChessNotation(row, col)
    local columns = "ABCDEFGH"
    local column = string.sub(columns, col, col)
    return column .. row
end

function gameRuler:addLogEntry(player, action, row, col, extraInfo)
    local playerPrefix = ""
    local action = action or ""
    if player then
        playerPrefix = "P" .. player
    end
    local coords = row and col and self:gridToChessNotation(row, col) or ""
    local entry = ""
    if playerPrefix then
        entry = playerPrefix .. " " .. action
    else
        entry = action
    end

    if coords ~= "" then
        entry = entry .. " " .. coords
    end

    if extraInfo then
        entry = entry .. " " .. extraInfo
    end

    -- Insert at the beginning (newest first)
    table.insert(self.turnLog, 1, entry)
    self:appendLastGameLogLine(entry, player)
end

function gameRuler:addLogEntryString(string)
    -- Insert at the beginning (newest first)
    table.insert(self.turnLog, 1, string)
    self:appendLastGameLogLine(string, nil)
end

function gameRuler:playerHasUnitsLeft(playerNum)
    -- Check grid for any units of this player
    if self.currentGrid then
        for row = 1, self.currentGrid.rows do
            for col = 1, self.currentGrid.cols do
                local unit = self.currentGrid:getUnitAt(row, col)
                if unit and unit.player == playerNum and unit.name ~= "Commandant" then
                    return true
                end
            end
        end
    end

    self:addLogEntryString("P" .. self.currentPlayer .. " WIN! P" .. playerNum .. " has no units left")

    -- Check player's supply
    local supply = playerNum == 1 and self.player1Supply or self.player2Supply
    if supply and #supply > 0 then
        return true
    end

    -- No units found anywhere
    return false
end

function gameRuler:calculateDamage(attackingUnit, defendingUnit)
    -- Use centralized damage calculation from unitsInfo
    return unitsInfo:calculateAttackDamage(attackingUnit, defendingUnit)
end

function gameRuler:hasLineOfSight(from, to, attacker)
    if not from or not to then return false end

    if from.row == to.row and from.col == to.col then
        return true
    end

    if from.row ~= to.row and from.col ~= to.col then
        return false
    end

    local path = self:getLinePath(from, to)

    for i = 2, #path - 1 do
        local pos = path[i]
        local ignoreBlockers = attacker and attacker.name == "Artillery"
        if not ignoreBlockers and self:isPositionBlocked(pos.row, pos.col) then
            return false
        end
    end

    return true
end

function gameRuler:getLinePath(from, to)
    local path = {}
    local dx = to.col - from.col
    local dy = to.row - from.row
    
    -- Only orthogonal movement allowed - no diagonal paths
    if dx ~= 0 and dy ~= 0 then
        return {}
    end
    
    local steps = math.abs(dx) + math.abs(dy)

    if steps == 0 then
        table.insert(path, {row = from.row, col = from.col})
        return path
    end

    -- Only horizontal or vertical movement allowed
    if dx ~= 0 then
        -- Horizontal movement only
        local stepDirection = dx > 0 and 1 or -1
        for i = 0, math.abs(dx) do
            table.insert(path, {row = from.row, col = from.col + (stepDirection * i)})
        end
    else
        -- Vertical movement only
        local stepDirection = dy > 0 and 1 or -1
        for i = 0, math.abs(dy) do
            table.insert(path, {row = from.row + (stepDirection * i), col = from.col})
        end
    end

    return path
end

function gameRuler:isPositionBlocked(row, col)
    -- Check if position is out of bounds
    if not self.currentGrid or not self.currentGrid:isValidPosition(row, col) then
        return true
    end
    
    -- Check if there's a unit at this position using the grid's method
    local unit = self.currentGrid:getUnitAt(row, col)
    return unit ~= nil
end

function gameRuler:findPlayerCommandHub(playerNum)
    if not self.currentGrid then
        return nil
    end
    
    -- Search the grid for the player's Commandant
    for row = 1, self.currentGrid.rows do
        for col = 1, self.currentGrid.cols do
            local unit = self.currentGrid:getUnitAt(row, col)
            if unit and unit.player == playerNum and unit.name == "Commandant" then
                return {
                    unit = unit,
                    row = row,
                    col = col
                }
            end
        end
    end
    
    return nil
end

function gameRuler:isScenarioMode()
    return GAME
        and GAME.CURRENT
        and GAME.MODE
        and GAME.CURRENT.MODE == GAME.MODE.SCENARIO
end

function gameRuler:getScenarioTurnLimit()
    local scenario = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
    local turnsTarget = scenario and tonumber(scenario.turnsTarget) or nil
    if not turnsTarget or turnsTarget < 1 then
        return nil
    end
    return math.floor(turnsTarget)
end

function gameRuler:countPlayerUnitsOnBoard(playerNum)
    if not self.currentGrid then
        return 0
    end

    local count = 0
    for row = 1, self.currentGrid.rows do
        for col = 1, self.currentGrid.cols do
            local unit = self.currentGrid:getUnitAt(row, col)
            if unit and unit.player == playerNum and unit.name ~= "Rock" then
                count = count + 1
            end
        end
    end
    return count
end

function gameRuler:evaluateScenarioEndConditions(source)
    if not self:isScenarioMode() or self.currentPhase == PHASES.GAME_OVER then
        return false
    end

    -- Scenario victory is only possible by destroying the Red Commandant.
    local redCommandant = self:findPlayerCommandHub(2)
    if not redCommandant then
        self:addLogEntryString("SCENARIO CLEAR! Red Commandant destroyed.")
        self.winner = 1
        self.lastVictoryReason = "scenario_red_commandant_destroyed"
        self:setPhase(PHASES.GAME_OVER)
        return true
    end

    -- Scenario defeat if no Blue units remain on the battlefield.
    if self:countPlayerUnitsOnBoard(1) <= 0 then
        self:addLogEntryString("SCENARIO FAILED! No Blue units remain.")
        self.winner = 2
        self.lastVictoryReason = "scenario_blue_units_eliminated"
        self:setPhase(PHASES.GAME_OVER)
        return true
    end

    -- Scenario defeat at the start of Blue turn N+1 when limit is N.
    local turnsLimit = self:getScenarioTurnLimit()
    if turnsLimit
        and self.currentPlayer == 1
        and (tonumber(self.currentTurn) or 0) > turnsLimit then
        self:addLogEntryString("SCENARIO FAILED! Turn limit exceeded (" .. tostring(turnsLimit) .. ").")
        self.winner = 2
        self.lastVictoryReason = "scenario_turn_limit"
        self:setPhase(PHASES.GAME_OVER)
        return true
    end

    return false
end

function gameRuler:getAdjacentCells(row, col)
    local adjacentCells = {}

    -- Define the four orthogonal directions
    local directions = {
        {row = 0, col = 1},   -- Right
        {row = 1, col = 0},   -- Down
        {row = 0, col = -1},  -- Left
        {row = -1, col = 0}   -- Up
    }

    -- Check each direction
    for _, dir in ipairs(directions) do
        local adjRow = row + dir.row
        local adjCol = col + dir.col

        -- Only include valid positions (don't worry about what's in them)
        if self.currentGrid:isValidPosition(adjRow, adjCol) then
            table.insert(adjacentCells, {
                row = adjRow,
                col = adjCol
            })
        end
    end

    return adjacentCells
end

function gameRuler:executeCommandHubDefense()
    -- Set flag to disable the button
    self.commandHubDefenseActive = true
    self.commandHubDefenseComplete = false

    -- **FIX: Wait for all animations to complete before starting Commandant defense**
    local function waitForAnimationsAndExecute()
        -- Check if there are any moving units or animations still running
        if self.currentGrid and self.currentGrid.movingUnits and #self.currentGrid.movingUnits > 0 then
            -- Wait a bit longer and check again
            self:scheduleAction(0.3, waitForAnimationsAndExecute)
            return
        end
        
        self:executeCommandHubDefenseInternal()
    end
    
    -- Start the animation check
    waitForAnimationsAndExecute()
    return true
end

function gameRuler:executeCommandHubDefenseInternal()
    -- Find the current player's Commandant
    local currentPlayer = self.currentPlayer
    local commandHub = self:findPlayerCommandHub(currentPlayer)
    if not commandHub then
        if self:isScenarioMode() then
            self:scheduleAction(0.05, function()
                self.commandHubDefenseComplete = true
                self.commandHubDefenseActive = false
                self:nextTurnPhase()
            end)
            return true
        end
        return false
    end
    
    -- In AI vs AI mode, show the Commandant's info in the info panel
    if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI and GAME.CURRENT.UI then
        local ui = GAME.CURRENT.UI
        if commandHub and ui.createUnitInfoFromUnit and ui.setContent then
            -- Get the actual unit from the grid to ensure we have all the data
            local gridUnit = self.currentGrid:getUnitAt(commandHub.row, commandHub.col)
            if gridUnit then
                logger.debug("GAMEPLAY", "AI vs AI: Showing Commandant defense info for player", currentPlayer, "- HP:", gridUnit.currentHp)
                local unitInfo = ui:createUnitInfoFromUnit(gridUnit, currentPlayer)
                ui:setContent(unitInfo, ui.playerThemes[currentPlayer] or ui.playerThemes[0])
                ui.forceInfoPanelDefault = false
            else
                logger.error("GAMEPLAY", "AI vs AI: ERROR - Could not find Commandant unit on grid at", commandHub.row, commandHub.col)
            end
        end
    end

    -- Get adjacent cells to scan
    local adjacentCells = self:getAdjacentCells(commandHub.row, commandHub.col)

    -- **NEW: Create the scanning effect**
    if self.currentGrid then
        -- Prepare scan data with unit information
        local scanCells = {}
        for _, cell in ipairs(adjacentCells) do
            local unit = self.currentGrid:getUnitAt(cell.row, cell.col)
            table.insert(scanCells, {
                row = cell.row,
                col = cell.col,
                hasUnit = unit ~= nil,
                unitType = unit and unit.name or nil
            })
        end

        -- Create the fantastic scan effect
        self.currentGrid:createCommandHubScanEffect(commandHub.row, commandHub.col, scanCells)
    end

    -- Get the current player's Commandant position
    local hubPos = self.commandHubPositions[currentPlayer]
    if not hubPos then
        self:scheduleAction(0.2, function()
            self.commandHubDefenseActive = false
            self:nextTurnPhase()
        end)
        return false
    end

    -- Define directions in clockwise order
    local clockwiseDirections = {
        {row = 0, col = 1},  -- Right
        {row = 1, col = 0},  -- Down
        {row = 0, col = -1}, -- Left
        {row = -1, col = 0}  -- Up
    }

    -- Track which direction we're currently processing
    local currentDirectionIndex = 1

    -- Function to process a single direction
    local function processNextDirection()
        -- Safety check for hubPos
        if not hubPos then
            self:nextTurnPhase()
            return
        end

        -- If processed all directions, end the phase
        if currentDirectionIndex > #clockwiseDirections then
            -- Set a flag to indicate completion state
            self.commandHubDefenseComplete = true
            -- Automatically go to end turn phase after a short delay
            self:scheduleAction(0.5, function()
                -- Only set to false during phase transition to avoid button spamming
                self.commandHubDefenseActive = false
                self:nextTurnPhase()
            end)
            return
        end

        local dir = clockwiseDirections[currentDirectionIndex]
        local targetRow = hubPos.row + dir.row
        local targetCol = hubPos.col + dir.col

        -- Check if a position is valid
        if self.currentGrid:isValidPosition(targetRow, targetCol) then
            -- **FIX: Re-check grid state to ensure unit still exists**
            local targetUnit = self.currentGrid:getUnitAt(targetRow, targetCol)

            -- Only process enemy units (not empty cells, not current player's friendly units)
            if targetUnit and targetUnit.player ~= currentPlayer and targetUnit.player ~= 0 then

                -- Any Commandant attack is interaction for draw-counter purposes.
                if DRAW_RULES.RESET_ON_COMMANDANT_ATTACK ~= false then
                    self:resetNoInteractionCounter("commandant_attack")
                end

                -- Attack enemy logic
                self.currentGrid:flashCell(targetRow, targetCol, {190/255, 76/255, 60/255})

                self:addLogEntry(self.currentPlayer,
                    "CH in ",
                    hubPos.row,
                    hubPos.col,
                    "attack " .. targetUnit.shortName .. " in " .. self:gridToChessNotation(targetRow, targetCol)
                )

                self.currentGrid:createTeslaStrike(hubPos.row, hubPos.col, targetRow, targetCol)

                if not targetUnit.currentHp then
                    targetUnit.currentHp = targetUnit.startingHp
                end

                local damage = self:calculateDamage(self.currentGrid:getUnitAt(hubPos.row, hubPos.col), targetUnit)
                targetUnit.currentHp = targetUnit.currentHp - damage

                local attackingUnit = self.currentGrid:getUnitAt(hubPos.row, hubPos.col)
                -- Update damage stats
                self.gameStats.players[self.currentPlayer].damageDealt = self.gameStats.players[self.currentPlayer].damageDealt + damage

                -- Only update damage taken for actual players (not neutrals)
                local targetPlayer = tonumber(targetUnit.player) or 0
                if targetPlayer > 0 then
                    self.gameStats.players[targetPlayer].damageTaken = self.gameStats.players[targetPlayer].damageTaken + damage
                end

                -- Similarly for unit destruction
                if targetUnit.currentHp <= 0 then
                    self.gameStats.players[self.currentPlayer].unitsDestroyed = self.gameStats.players[self.currentPlayer].unitsDestroyed + 1

                    -- Only count losses for actual players
                    if targetPlayer > 0 then
                        self.gameStats.players[targetPlayer].unitsLost = self.gameStats.players[targetPlayer].unitsLost + 1
                    end
                end
                -- Update unit type stats
                if self.gameStats.unitStats[attackingUnit.name] then
                    self.gameStats.unitStats[attackingUnit.name].damageDealt = 
                        self.gameStats.unitStats[attackingUnit.name].damageDealt + damage
                end

                -- If the unit is destroyed
                if targetUnit.currentHp <= 0 then

                    self.currentGrid:createDestructionEffect(targetRow, targetCol, targetUnit.playerColor)

                    -- Play unit destruction sound
                    if SETTINGS.AUDIO.SFX then
                        soundCache.play("assets/audio/Success6.wav", {
                            volume = SETTINGS.AUDIO.SFX_VOLUME
                        })
                    end

                    self.currentGrid:addFloatingText(targetRow, targetCol, damage, false, "assets/audio/Success3.wav")

                    self:addLogEntry(
                        self.currentPlayer,
                        "CH in",
                        hubPos.row, hubPos.col,
                        "destroy " .. targetUnit.shortName .. " in " .. self:gridToChessNotation(targetRow, targetCol)
                    )

                    -- Remove from grid
                    self.currentGrid:removeUnit(targetRow, targetCol)

                    if self:isScenarioMode() then
                        self:scheduleAction(0.3, function()
                            self:evaluateScenarioEndConditions("scenario_commandant_defense_destroy")
                        end)
                    else
                        -- Check if the target player has any units left
                        if not self:playerHasUnitsLeft(self:getOpponentPlayer()) then
                            -- No units left, game over
                            self.winner = self.currentPlayer
                            self.lastVictoryReason = "elimination"
                            self:setPhase(PHASES.GAME_OVER)
                            return true
                        end
                    end
                else
                    self.currentGrid:applyDamageFlash(targetRow, targetCol, 0.1)
                    self.currentGrid:addFloatingText(targetRow, targetCol, damage, false, "assets/audio/Success3.wav")

                    self:addLogEntry(
                        targetUnit.player,
                        targetUnit.shortName .. " in",
                        targetRow, targetCol,
                        "HP " .. targetUnit.currentHp
                    )
                end
            else
                -- Empty cell or friendly unit
                if not targetUnit then
                else
                end

                self.currentGrid:flashCell(targetRow, targetCol, {68/255, 137/255, 72/255})

                -- Play highlight sound for every cell that gets highlighted
                if SETTINGS.AUDIO.SFX then
                    soundCache.play("assets/audio/SciFiNotification1.wav", {
                        volume = SETTINGS.AUDIO.SFX_VOLUME * 0.8
                    })
                end

                self:addLogEntry(
                    self.currentPlayer,
                    "CM in",
                    hubPos.row, hubPos.col,
                    "scan check in " .. self:gridToChessNotation(targetRow, targetCol)
                )
            end
        end

        -- Move to the next direction
        currentDirectionIndex = currentDirectionIndex + 1

        -- Schedule next direction with delay
        self:scheduleAction(0.4, processNextDirection)
    end

    -- Start processing the first direction immediately
    processNextDirection()

    return true
end

function gameRuler:areActionsComplete()
    return self.currentTurnActions >= self.maxActionsPerTurn
end

function gameRuler:replenishPlayerSupply()
    local playerNum = self.currentPlayer
    local supply = nil

    -- Get the correct supply array
    if playerNum == 1 then
        if not self.player1Supply then
            self.player1Supply = {}
        end
        supply = self.player1Supply
    else
        if not self.player2Supply then
            self.player2Supply = {}
        end
        supply = self.player2Supply
    end

    return true
end

-- Set phase with specified phase name (and optionally turn phase)
function gameRuler:setPhase(phaseName, turnPhaseName)
    -- Set new phase
    self.currentPhase = phaseName
    if turnPhaseName then
        self.currentTurnPhase = turnPhaseName
    end

    if phaseName == PHASES.GAME_OVER then
        if self.ui then
            self.ui.navigationMode = "ui"
            self.ui.uIkeyboardNavigationActive = true
            self.ui:initializeUIElements()

            -- Set focus on toggle button
            for i, element in ipairs(self.ui.uiElements) do
                if element.name == "toggleButton" then
                    self.ui.currentUIElementIndex = i
                    self.ui.activeUIElement = element
                    self.ui:syncKeyboardAndMouseFocus()
                    break
                end
            end
        end

        self.gameTimer.endTime = love.timer.getTime()
        self.gameTimer.totalGameTime = self.gameTimer.endTime - self.gameTimer.startTime
        self.gameTimer.isRunning = false

        for player = 1, 2 do
            -- Average actions per turn
            if self.gameStats.turns > 0 then
                self.gameStats.players[player].avgActionsPerTurn = 
                    self.gameStats.players[player].actionsUsed / self.gameStats.turns
            else
                self.gameStats.players[player].avgActionsPerTurn = 0
            end
        end

        -- Find most effective unit
        local highestDamage = 0
        local mostEffectiveUnit = "None"
        for unitName, stats in pairs(self.gameStats.unitStats) do
            if stats.damageDealt > highestDamage then
                highestDamage = stats.damageDealt
                mostEffectiveUnit = unitName
            end
        end
        self.gameStats.mostEffectiveUnit = mostEffectiveUnit
    end

    if turnPhaseName then
        self.currentTurnPhase = turnPhaseName
    end

    -- Phase-specific flow
    if phaseName == PHASES.DEPLOY1 or phaseName == PHASES.DEPLOY2 then
        -- Update player number based on phase
        self.currentPlayer = (phaseName == PHASES.DEPLOY1) and 1 or 2
        -- Update grid highlights for the current player
        self:updateGridHighlights()
    elseif phaseName == PHASES.TURN and turnPhaseName == TURN_PHASES.ACTIONS then
        -- Reset actions at the start of actions phase
        self.currentTurnActions = 0
        self.hasDeployedThisTurn = false
        -- Recalculate possible actions for this turn
        self:recalculateMaxActions() 
    elseif phaseName == PHASES.TURN and turnPhaseName == TURN_PHASES.COMMAND_HUB then
        -- Initialize Commandant defense state without auto-starting
        self.commandHubDefenseActive = false
    end
end

-- Add around line 2950:
function gameRuler:canDeployInActionsPhase()
    -- Check if already deployed this turn
    if self.hasDeployedThisTurn then
        return false
    end
    
    -- Check if we have actions remaining
    if self:areActionsComplete() then
        return false
    end
    
    -- Check if we have a Commandant
    local hubPos = self.commandHubPositions[self.currentPlayer]
    if not hubPos then
        return false
    end

    -- Check if there are free cells around the Commandant
    local freeCells = self:getFreeCellsAroundPosition(hubPos.row, hubPos.col)
    if not freeCells or #freeCells == 0 then
        return false
    end

    -- Check if there are units in supply
    local supply = nil
    if self.currentPlayer == 1 then
        supply = self.player1Supply
    else
        supply = self.player2Supply
    end

    if not supply or #supply == 0 then
        return false
    end

    return true
end

function gameRuler:handleUnitWithNoValidActions(row, col)
    local unit = self.currentGrid:getUnitAt(row, col)
    if not unit or unit.player ~= self.currentPlayer or unit.hasActed then
        return false
    end
    
    -- ONLY AUTO-MARK IF IT'S THE LAST POSSIBLE ACTION
    -- Check if we're at the action limit (only 1 action remaining)
    local actionsRemaining = self.maxActionsPerTurn - self.currentTurnActions
    if actionsRemaining > 1 then
        return false -- Don't auto-mark if player has multiple actions left
    end
    
    -- Check if this specific unit has any valid actions
    if not self:unitHasValidActions(row, col) then
        -- ADDITIONAL CHECK: Are there other units that can still act?
        if self:hasOtherUnitsWithValidActions(row, col) then
            return false -- Don't auto-mark if other units can still act
        end
        
        -- Only now mark unit as acted since it's truly the last option
        unit.hasActed = true
        
        -- Count this as an action used
        self.currentTurnActions = (self.currentTurnActions or 0) + 1
        
        -- Recalculate possible actions after this movement
        -- This handles cases where moving one unit unblocks another unit's actions
        self:recalculateMaxActions()
        
        
        -- Add log entry
        self:addLogEntry(
            self.currentPlayer,
            unit.shortName .. " in",
            row, col,
            "no valid actions - skipped"
        )
        
        -- Clear any previews
        if self.currentGrid then
            self.currentGrid:clearActionHighlights()
            self.currentGrid:clearForcedHighlightedCells()
        end
        
        -- Check if all units are now stalled
        self:checkForStalledUnits()
        
        return true -- Unit was automatically marked as acted
    end
    
    return false -- Unit has valid actions
end

function gameRuler:hasOtherUnitsWithValidActions(excludeRow, excludeCol)
    if not self.currentGrid then return false end
    
    for row = 1, self.currentGrid.rows do
        for col = 1, self.currentGrid.cols do
            -- Skip the unit we're checking and Commandants - use proper control flow
            if not (row == excludeRow and col == excludeCol) then
                local unit = self.currentGrid:getUnitAt(row, col)
                if unit and unit.player == self.currentPlayer and unit.name ~= "Commandant" and not unit.hasActed then
                    -- Check if this other unit has valid actions
                    if self:unitHasValidActions(row, col) then
                        return true -- Found another unit that can act
                    end
                end
            end
        end
    end
    
    return false -- No other units can act
end

function gameRuler:unitHasValidActions(row, col)
    local unit = self.currentGrid:getUnitAt(row, col)
    if not unit or unit.player ~= self.currentPlayer or unit.hasActed then
        return false
    end

    -- Initialize action tracking if needed
    if not unit.turnActions then
        unit.turnActions = {}
    end

    -- Check orthogonal directions
    local directions = {
        {row = 0, col = 1},  -- Right
        {row = 0, col = -1}, -- Left
        {row = 1, col = 0},  -- Down
        {row = -1, col = 0}  -- Up
    }

    -- Check if unit can move (only if haven't moved yet)
    if not unit.turnActions["move"] then
        -- Use centralized function to get move range with debug printing
        local movementRange = unitsInfo:getUnitMoveRange(unit, "GAME_RULER_GET_MOVE_CELLS")
        if movementRange > 0 then
            if unit.fly then
                -- FLYING UNITS: Can move to ANY empty cell within range (no line-of-sight blocking)
                for _, dir in ipairs(directions) do
                    for dist = 1, movementRange do
                        local r = row + (dir.row * dist)
                        local c = col + (dir.col * dist)
                        if self.currentGrid:isValidPosition(r, c) and self.currentGrid:isCellEmpty(r, c) then
                            return true -- Flying unit can move to some valid cell
                        end
                        -- Continue checking further cells even if this one is blocked
                    end
                end
            else
                -- NON-FLYING UNITS: Stop at first Rock
                for _, dir in ipairs(directions) do
                    for dist = 1, movementRange do
                        local r = row + (dir.row * dist)
                        local c = col + (dir.col * dist)
                        if self.currentGrid:isValidPosition(r, c) then
                            if self.currentGrid:isCellEmpty(r, c) then
                                return true -- Ground unit can move here
                            else
                                break -- Hit Rock, stop checking this direction
                            end
                        else
                            break -- Out of bounds, stop checking this direction
                        end
                    end
                end
            end
        end
    end

    -- Check if unit can attack (only if haven't attacked yet)
    if not unit.turnActions["attack"] then
        -- Use centralized function to get attack range with debug printing
        local attackRange = unitsInfo:getUnitAttackRange(unit, "GAME_RULER_GET_ATTACK_CELLS")
        if attackRange > 0 then
            -- Special cases for units with attack restrictions
            local isCorvette = (unit.name == "Cloudstriker")
            local isArtillery = (unit.name == "Artillery")

            for _, dir in ipairs(directions) do
                -- For corvettes, check line of sight blockage
                local isBlocked = false
                if isCorvette then
                    local adjRow = row + dir.row
                    local adjCol = col + dir.col
                    if self.currentGrid:isValidPosition(adjRow, adjCol) and self.currentGrid:getUnitAt(adjRow, adjCol) then
                        isBlocked = true
                    end
                end
                -- Artillery doesn't need line of sight checks (can shoot through Rocks)

                -- Skip adjacent cells for Corvette and Artillery
                local minRange = (isCorvette or isArtillery) and 2 or 1

                -- Only check if not blocked
                if not isBlocked then
                    for dist = minRange, attackRange do
                        local r = row + (dir.row * dist)
                        local c = col + (dir.col * dist)
                        if self.currentGrid:isValidPosition(r, c) then
                            local targetUnit = self.currentGrid:getUnitAt(r, c)
                            if targetUnit and targetUnit.player ~= self.currentPlayer then
                                return true -- Can attack an enemy
                            end
                            -- Stop at any unit
                            if targetUnit then break end
                        else
                            break -- Out of bounds, stop checking this direction
                        end
                    end
                end
            end
        end
    end

    -- Check if unit can repair (only if haven't repaired yet)
    if not unit.turnActions["repair"] and unit.repair then
        local repairRange = unit.repairRange or 1
        for _, dir in ipairs(directions) do
            for dist = 1, repairRange do
                local r = row + (dir.row * dist)
                local c = col + (dir.col * dist)
                if self.currentGrid:isValidPosition(r, c) then
                    local targetUnit = self.currentGrid:getUnitAt(r, c)
                    if targetUnit and targetUnit.player == self.currentPlayer then
                        return true -- Can repair a friendly unit
                    end
                    -- Stop at any unit
                    if targetUnit then break end
                else
                    break -- Out of bounds, stop checking this direction
                end
            end
        end
    end

    return false -- No valid actions found
end

-- Move to the next main game phase
function gameRuler:nextGamePhase()
    local nextPhase = PHASE_TRANSITIONS[self.currentPhase]
    if not nextPhase then
        return false
    end

    -- Special handling for turn phase initialization
    if nextPhase == PHASES.TURN then
        -- When entering turn phase, start with actions and player 1
        self:setPhase(nextPhase, TURN_PHASES.ACTIONS)
        self.currentPlayer = 1
        -- Clear highlights when entering turn phase
        if self.currentGrid then
            self.currentGrid:clearHighlightedCells()
        end
        -- Recalculate max actions based on current unit count
        self:recalculateMaxActions()
    else
        self:setPhase(nextPhase)
    end

    if self.currentGrid then
        self.currentGrid:clearActionHighlights()
    end

    return true
end

function gameRuler:nextTurnPhase()
    if self.currentPhase ~= PHASES.TURN then
        return false
    end

    local nextTurnPhase = TURN_PHASE_TRANSITIONS[self.currentTurnPhase]
    if nextTurnPhase then
        if not self.drawGame and not self.noMoreUnitsGameOver then
            self:setPhase(PHASES.TURN, nextTurnPhase)


            if self.currentGrid then
                self.currentGrid:clearActionHighlights()
            end

            return true
        else
            return false
        end
    end
    return false
end

function gameRuler:resetNoInteractionCounter(reason)
    self.turnsWithoutDamage = 0
    self.turnHadInteraction = true
    self.onlineDrawOfferPending = false
    return self.turnsWithoutDamage
end

function gameRuler:consumeOnlineDrawOfferPending()
    if self.onlineDrawOfferPending then
        self.onlineDrawOfferPending = false
        return true
    end
    return false
end

function gameRuler:incrementNoInteractionCounterPerPlayerTurn()
    local startTurn = DRAW_RULES.START_TURN or 10
    if (self.currentTurn or 0) >= startTurn then
        if self.turnHadInteraction then
            self.turnsWithoutDamage = 0
        else
            self.turnsWithoutDamage = (self.turnsWithoutDamage or 0) + 1
        end
    end
    return self.turnsWithoutDamage or 0
end

function gameRuler:checkDrawConditions()
    -- Increment once per player turn.
    self:incrementNoInteractionCounterPerPlayerTurn()
    local drawLimit = DRAW_RULES.NO_INTERACTION_LIMIT or GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE
    local earlyOfferTurn = math.floor(drawLimit / 2)

    -- Check for early draw offer at halfway point
    if self.turnsWithoutDamage == earlyOfferTurn then
        -- Only show this for human players, not when AI is playing
        if GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL then
            -- Show confirmation dialog
            ConfirmDialog.show(
                "STALEMATE DETECTED\n\nDraw the game now?",
                function()
                    -- Confirmed - end in draw now
                    self:addLogEntryString("GAME DRAW AT TURN " .. self.currentTurn)
                    self.winner = 0
                    self.lastVictoryReason = "draw"
                    self.drawGame = true
                    self:setPhase(PHASES.GAME_OVER)
                    return true
                end,
                function()
                    return false
                end
            )
        elseif GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET then
            self.onlineDrawOfferPending = true
        end
    end

    -- Check for draw condition
    if self.turnsWithoutDamage >= drawLimit then
        -- Log the draw
        self:addLogEntryString(tostring(drawLimit) .. " no fight turns")
        self:addLogEntryString("GAME DRAW AT TURN " .. self.currentTurn)

        self.winner = 0
        self.lastVictoryReason = "draw"
        self.drawGame = true
        self:setPhase(PHASES.GAME_OVER)
        return true
    end
    return false
end

function gameRuler:checkNoMoreUnitsGameOverConditions()
    if self:isScenarioMode() then
        return self:evaluateScenarioEndConditions("scenario_unit_check")
    end

    if not self:playerHasUnitsLeft(self.currentPlayer) then
        -- No units left - game over
        self.winner = self:getOpponentPlayer()
        self.lastVictoryReason = "elimination"
        self:setPhase(PHASES.GAME_OVER)
        self.noMoreUnitsGameOver = true
        return true
    end

    return false
end

function gameRuler:nextTurn()
    -- Update the current player's time
    local currentTime = love.timer.getTime()
    local timeSpent = currentTime - self.gameTimer.currentPlayerStartTime

    -- Add the time to the appropriate player
    self.gameTimer.playerTime[self.currentPlayer] = self.gameTimer.playerTime[self.currentPlayer] + timeSpent

    -- Reset the start time for the next player
    self.gameTimer.currentPlayerStartTime = currentTime

    if self:isScenarioMode() then
        if self:evaluateScenarioEndConditions("scenario_pre_next_turn") then
            return true
        end
    else
        if self:checkNoMoreUnitsGameOverConditions() then
            return true
        end
    end

    -- Reset damage flags for the current player's units before switching turns
    self:resetDamageFlags(self.currentPlayer)

    -- Draw counter is evaluated once per player turn.
    if not self:isScenarioMode() then
        if self:checkDrawConditions() then
            return true
        end
    end
    
    -- Switch players and increment turn counter when needed
    if self.currentPlayer == 1 then
        self.currentPlayer = 2
    else
        self.currentTurn = self.currentTurn + 1
        GAME.CURRENT.TURN = self.currentTurn
        self.currentPlayer = 1

        if self:isScenarioMode() and self:evaluateScenarioEndConditions("scenario_blue_turn_start") then
            return true
        end

        -- Schedule the start-of-turn presentation without delaying gameplay logic
        self:scheduleAction(0.2, function()
            if GAME.CURRENT.UI and GAME.CURRENT.UI.startTurnZoom then
                GAME.CURRENT.UI:startTurnZoom()
            end

            if SETTINGS.AUDIO.SFX then
                soundCache.play("assets/audio/SnappyButton2.wav", {
                    volume = SETTINGS.AUDIO.SFX_VOLUME
                })
            end
        end)

        -- Log turn start immediately so it always appears before command hub scans/attacks.
        self:addLogEntryString("Turn " .. self.currentTurn .. " begins")

        -- Finalize immediately so Commandant defense timing matches both players
        self:finalizeTurnTransition()
        return false
    end

    self:finalizeTurnTransition()

    return true
end


function gameRuler:finalizeTurnTransition()
    self.currentTurnPhase = TURN_PHASES.COMMAND_HUB
    self.turnHadInteraction = false

    -- Commandant should attack at the START of every player's turn
    self:scheduleAction(0.1, function()
        self:executeCommandHubDefense()
    end)

    -- Reset actions counter
    self.currentTurnActions = 0

    -- Reset deployment tracking
    self.hasDeployedThisTurn = false

    -- Reset all units' "hasActed" flag AND action tracking
    if self.currentGrid then
        for row = 1, self.currentGrid.rows do
            for col = 1, self.currentGrid.cols do
                local unit = self.currentGrid:getUnitAt(row, col)
                if unit then
                    unit.hasActed = false
                    unit.turnActions = {}
                    unit.actionsUsed = 0
                end
            end
        end
    end

    -- Initialize action tracking for the new turn
    self:initializeUnitActionTracking()

    self:recalculateMaxActions()

    -- Update game stats
    self.gameStats.turns = self.gameStats.turns + 1
    self.gameStats.players[self.currentPlayer].actionsUsed = self.gameStats.players[self.currentPlayer].actionsUsed + self.currentTurnActions

    return true
end

-- Reset damage flags for all units belonging to the specified player
function gameRuler:resetDamageFlags(playerNumber)
    
    if not self.currentGrid then return end
    
    local flagsReset = 0
    
    -- Reset flags for all units on the grid belonging to this player
    for row = 1, self.currentGrid.rows do
        for col = 1, self.currentGrid.cols do
            local unit = self.currentGrid:getUnitAt(row, col)
            if unit and unit.player == playerNumber then
                -- Reset corvette damage flag
                if unit.corvetteDamageFlag then
                    unit.corvetteDamageFlag = false
                    flagsReset = flagsReset + 1
                end
                
                -- Reset artillery damage flag
                if unit.artilleryDamageFlag then
                    unit.artilleryDamageFlag = false
                    flagsReset = flagsReset + 1
                end
            end
        end
    end
    
    -- Also reset flags for Commandants
    if self.commandHubs and self.commandHubs[playerNumber] then
        local hub = self.commandHubs[playerNumber]
        if hub.corvetteDamageFlag then
            hub.corvetteDamageFlag = false
            flagsReset = flagsReset + 1
        end
        if hub.artilleryDamageFlag then
            hub.artilleryDamageFlag = false
            flagsReset = flagsReset + 1
        end
    end
    
end

-- Update grid highlights based on current phase
function gameRuler:updateGridHighlights()
    if not self.currentGrid then return end

    if self.currentPhase == PHASES.DEPLOY1 or self.currentPhase == PHASES.DEPLOY2 then
        -- Highlight valid cells for Commandant placement
        local validRows = self.commandHubsValidPositions[self.currentPlayer]
        self.currentGrid:highlightValidCells(validRows, nil, self.currentPlayer)
    else
        -- Clear highlights for other phases
        self.currentGrid:clearHighlightedCells()
    end
end

function gameRuler:countCurrentPlayerUnits()
    if not self.currentGrid then
        return 0
    end
    
    local count = 0
    
    for row = 1, self.currentGrid.rows do
        for col = 1, self.currentGrid.cols do
            local unit = self.currentGrid:getUnitAt(row, col)
            if unit and unit.player == self.currentPlayer and unit.name ~= "Commandant" then
                count = count + 1
            end
        end
    end
    
    return count
end

--------------------------------------------------
-- SUPPLY MANAGEMENT
--------------------------------------------------

function gameRuler:getCurrentPlayerSupply(factionId)
    factionId = factionId or self.currentPlayer
    return self.playerSupplies and self.playerSupplies[factionId]
end

-- Create initial supply for a player
function gameRuler:createInitialSupply(factionId)
    local supply = {}

    local unitTypes = {
        "Commandant",
        "Wingstalker",
        "Wingstalker",
        "Crusher",
        "Crusher",
        "Crusher",
        "Bastion",
        "Bastion",
        "Cloudstriker",
        "Cloudstriker",
        "Cloudstriker",
        "Earthstalker",
        "Earthstalker",
        "Healer",
        "Artillery",
        "Artillery"
    }

    for _, unitType in ipairs(unitTypes) do
        local unit = unitsInfo:getUnitInfo(unitType)
        
        -- Check if unit exists to prevent nil errors - use proper control flow
        if unit then
            -- Create a deep copy to avoid shared references
            local unitCopy = {}
            for k, v in pairs(unit) do
                unitCopy[k] = v
            end

            -- Set player ownership and clean any action flags
            unitCopy.player = factionId
            self:cleanUnitActionData(unitCopy)

            table.insert(supply, unitCopy)
        else
        end
    end

    return supply
end

--------------------------------------------------
-- GAME STATE MANAGEMENT
--------------------------------------------------

-- Reset the game to initial state
function gameRuler:resetGame()
    self.currentTurn = 0
    self.currentPlayer = 1
    self.currentPhase = PHASES.SETUP
    self.currentTurnPhase = TURN_PHASES.COMMAND_HUB
    self.currentUnit = nil
    self.currentTarget = nil
    self.neutralBuildings = {}
    self.commandHubPositions = {}
    self.tempCommandHubPosition = {}
    self.currentTurnActions = 0
    self.winner = nil
    self.lastVictoryReason = nil
    self.commandHubPlacementReady = false
    self.turnLog = {}
    self:resetLastGameLogFile("reset_game")
    if debugConsoleLog and debugConsoleLog.reset then
        debugConsoleLog.reset("reset_game")
    end
    self:initializeLogicRng(self.logicRngSeed or GAME.CURRENT.SEED or randomGenerator.getSeed() or 1)
    self.turnsWithoutDamage = 0
    self.turnHadInteraction = false
    self.drawGame = false
    self.onlineDrawOfferPending = false
    self.noMoreUnitsGameOver = false
    self.hasDeployedThisTurn = false
    -- Don't reset neutralBuildingsPlaced here - let placeNeutralBuilding initialize it
    self.targetRows = OBSTACLE_RULES.ROWS or {3, 4, 5, 6}
    self.usedRows = {}
    self.initialDeployment = {
        requiredDeployments = INITIAL_DEPLOY_RULES.COUNT or 1,
        completedDeployments = 0,
        availableCells = {},
        selectedUnitIndex = nil
    }
    self.playerSupplies[1] = self:createInitialSupply(1)
    self.playerSupplies[2] = self:createInitialSupply(2)
    self:cleanSupplyUnitData(self.playerSupplies[1])
    self:cleanSupplyUnitData(self.playerSupplies[2])
    if self.currentGrid then
        for row = 1, self.currentGrid.rows do
            for col = 1, self.currentGrid.cols do
                local unit = self.currentGrid:getUnitAt(row, col)
                if unit then
                    self:cleanUnitActionData(unit)
                end
                self.currentGrid:removeUnit(row, col)
            end
        end
        self.currentGrid:clearHighlightedCells()
        self.currentGrid:clearForcedHighlightedCells()
        self.currentGrid:clearActionHighlights()
    end
    if self.gameTimer then
        self.gameTimer.startTime = love.timer.getTime()
        self.gameTimer.endTime = nil
        self.gameTimer.isRunning = true
        self.gameTimer.totalGameTime = 0
        self.gameTimer.lastTurnChangeTime = love.timer.getTime()
        self.gameTimer.currentPlayerStartTime = love.timer.getTime()
        self.gameTimer.playerTime = {[1] = 0, [2] = 0}
    end
    self.gameStats = {
        startTime = love.timer.getTime(),
        endTime = nil,
        totalGameTime = 0,
        turns = 0,
        neutralBuildingsDestroyed = 0,
        players = {
            [1] = {
                damageDealt = 0, damageTaken = 0, unitsDeployed = 0,
                unitsLost = 0, unitsDestroyed = 0, actionsUsed = 0,
                repairPoints = 0, commandHubAttacksSurvived = 0
            },
            [2] = {
                damageDealt = 0, damageTaken = 0, unitsDeployed = 0,
                unitsLost = 0, unitsDestroyed = 0, actionsUsed = 0,
                repairPoints = 0, commandHubAttacksSurvived = 0
            }
        },
        unitStats = {}
    }
    
    -- Initialize unit stats dynamically from unitsInfo
    local unitNames = unitsInfo:getAllUnitNames()
    for _, unitName in ipairs(unitNames) do
        self.gameStats.unitStats[unitName] = {deployed = 0, lost = 0, kills = 0, damageDealt = 0}
    end
    
    self:updateGridHighlights()
end

function gameRuler:cleanUnitActionData(unit)
    if not unit then return end

    -- Remove all action tracking flags
    unit.hasActed = nil
    unit.turnActions = nil
    unit.isAnimating = nil
    unit.justPlaced = nil
    unit.placedTime = nil
    unit.materializeProgress = nil
    unit.isHologram = nil

    -- Reset HP to starting value if it exists
    if unit.startingHp then
        unit.currentHp = unit.startingHp
    end
end

-- Clean all units in a supply array
function gameRuler:cleanSupplyUnitData(supply)
    if not supply then return end

    for _, unit in ipairs(supply) do
        self:cleanUnitActionData(unit)
    end
end

-- Set grid reference
function gameRuler:setGrid(grid)
    self.currentGrid = grid
    self:updateGridHighlights()
end

-- Check if a specific action is allowed in current phase
function gameRuler:isActionAllowed(actionType)
    -- Check based on current phase
    if self.currentPhase == PHASES.TURN then
        -- In turn phase, check against turn phase actions
        return TURN_PHASE_ACTIONS[self.currentTurnPhase] and TURN_PHASE_ACTIONS[self.currentTurnPhase][actionType] == true
    else
        -- In other phases, check against main phase actions
        return ALLOWED_ACTIONS[self.currentPhase] and ALLOWED_ACTIONS[self.currentPhase][actionType] == true
    end
end

-- Get current phase info for UI
function gameRuler:getCurrentPhaseInfo()
    local phaseInfo = {
        currentPhase = self.currentPhase,
        turnPhaseName = self.currentTurnPhase,
        currentTurn = self.currentTurn,
        currentPlayer = self.currentPlayer,
        actionsRemaining = self.maxActionsPerTurn - self.currentTurnActions,
        gamePhaseDesc = "",
        instructions = ""
    }

    -- Get base phase info
    local phaseData = PHASE_INFO[self.currentPhase]
    if phaseData then
        phaseInfo.gamePhaseDesc = phaseData.desc

        -- Get instructions - either directly or via function
        if type(phaseData.instructions) == "function" then
            phaseInfo.instructions = phaseData.instructions(self)
        else
            phaseInfo.instructions = phaseData.instructions
        end
    end

    -- For turn phase, get specific turn phase info
    if self.currentPhase == PHASES.TURN then
        local turnPhaseData = TURN_PHASE_INFO[self.currentTurnPhase]
        if turnPhaseData then
            phaseInfo.gamePhaseDesc = turnPhaseData.desc

            -- Get turn phase instructions
            if type(turnPhaseData.instructions) == "function" then
                phaseInfo.instructions = turnPhaseData.instructions(self)
            else
                phaseInfo.instructions = turnPhaseData.instructions
            end
        end
    end

    return phaseInfo
end

function gameRuler:getDeterministicStateSignature()
    local signature = {
        phase = self.currentPhase,
        turnPhase = self.currentTurnPhase,
        turn = self.currentTurn,
        player = self.currentPlayer,
        turnActions = self.currentTurnActions,
        maxActions = self.maxActionsPerTurn,
        turnsWithoutDamage = self.turnsWithoutDamage,
        drawGame = self.drawGame == true,
        winner = self.winner,
        logicRngState = self.logicRngState
    }

    local units = {}
    if self.currentGrid then
        for row = 1, self.currentGrid.rows do
            for col = 1, self.currentGrid.cols do
                local unit = self.currentGrid:getUnitAt(row, col)
                if unit then
                    units[#units + 1] = {
                        row = row,
                        col = col,
                        name = unit.name,
                        player = unit.player,
                        hp = unit.currentHp or unit.startingHp,
                        acted = unit.hasActed == true
                    }
                end
            end
        end
    end
    signature.units = units

    local supplies = {
        [1] = {},
        [2] = {}
    }
    for factionId = 1, 2 do
        local supply = self:getCurrentPlayerSupply(factionId) or {}
        for idx, unit in ipairs(supply) do
            supplies[factionId][idx] = {
                name = unit.name,
                hp = unit.currentHp or unit.startingHp
            }
        end
    end
    signature.supplies = supplies

    return signature
end

function gameRuler:buildResumeSnapshot()
    local snapshot = {
        version = 4,
        currentPhase = self.currentPhase,
        currentTurnPhase = self.currentTurnPhase,
        currentTurn = self.currentTurn,
        currentPlayer = self.currentPlayer,
        turnOrder = copySerializable(self.turnOrder),
        factionAssignments = copySerializable(self.factionAssignments),
        winner = self.winner,
        maxActionsPerTurn = self.maxActionsPerTurn,
        currentTurnActions = self.currentTurnActions,
        hasDeployedThisTurn = self.hasDeployedThisTurn == true,
        commandHubPositions = copySerializable(self.commandHubPositions),
        tempCommandHubPosition = copySerializable(self.tempCommandHubPosition),
        commandHubPlacementReady = self.commandHubPlacementReady == true,
        initialDeployment = {
            requiredDeployments = self.initialDeployment and self.initialDeployment.requiredDeployments or (INITIAL_DEPLOY_RULES.COUNT or 1),
            completedDeployments = self.initialDeployment and self.initialDeployment.completedDeployments or 0,
            selectedUnitIndex = self.initialDeployment and self.initialDeployment.selectedUnitIndex or nil,
            availableCells = copySerializable(self.initialDeployment and self.initialDeployment.availableCells or {})
        },
        turnsWithoutDamage = self.turnsWithoutDamage,
        turnHadInteraction = self.turnHadInteraction == true,
        drawGame = self.drawGame == true,
        noMoreUnitsGameOver = self.noMoreUnitsGameOver == true,
        logicRngSeed = self.logicRngSeed,
        logicRngState = self.logicRngState,
        neutralBuildings = copySerializable(self.neutralBuildings),
        neutralBuildingsPlaced = self.neutralBuildingsPlaced,
        targetRows = copySerializable(self.targetRows),
        usedRows = copySerializable(self.usedRows),
        actionsPhaseSupplySelection = self.actionsPhaseSupplySelection,
        playerSupplies = {
            [1] = {},
            [2] = {}
        },
        boardUnits = {},
        integritySignature = {
            boardUnitTotal = 0,
            boardByPlayer = { [0] = 0, [1] = 0, [2] = 0 },
            supplyByPlayer = { [1] = 0, [2] = 0 },
            commandants = { [1] = 0, [2] = 0 }
        }
    }

    for factionId = 1, 2 do
        local supply = self.playerSupplies and self.playerSupplies[factionId] or {}
        for _, unit in ipairs(supply or {}) do
            if unit and unit.name then
                snapshot.playerSupplies[factionId][#snapshot.playerSupplies[factionId] + 1] = {
                    name = unit.name,
                    player = tonumber(unit.player) or factionId,
                    currentHp = tonumber(unit.currentHp or unit.startingHp)
                }
                snapshot.integritySignature.supplyByPlayer[factionId] = (snapshot.integritySignature.supplyByPlayer[factionId] or 0) + 1
            end
        end
    end

    if self.currentGrid and self.currentGrid.rows and self.currentGrid.cols then
        for row = 1, self.currentGrid.rows do
            for col = 1, self.currentGrid.cols do
                local unit = self.currentGrid:getUnitAt(row, col)
                if unit and unit.name then
                    local unitPlayer = tonumber(unit.player)
                    if unit.name == "Commandant" and (unitPlayer ~= 1 and unitPlayer ~= 2) then
                        local midRow = math.floor((tonumber(self.currentGrid.rows) or 8) / 2)
                        unitPlayer = (row <= midRow) and 1 or 2
                    end

                    snapshot.boardUnits[#snapshot.boardUnits + 1] = {
                        row = row,
                        col = col,
                        name = unit.name,
                        player = unitPlayer,
                        currentHp = tonumber(unit.currentHp or unit.startingHp),
                        hasActed = unit.hasActed == true,
                        turnActions = copySerializable(unit.turnActions) or {}
                    }

                    local boardPlayer = tonumber(unitPlayer)
                    if boardPlayer ~= 0 and boardPlayer ~= 1 and boardPlayer ~= 2 then
                        boardPlayer = 0
                    end
                    snapshot.integritySignature.boardUnitTotal = (snapshot.integritySignature.boardUnitTotal or 0) + 1
                    snapshot.integritySignature.boardByPlayer[boardPlayer] = (snapshot.integritySignature.boardByPlayer[boardPlayer] or 0) + 1
                    if unit.name == "Commandant" and (boardPlayer == 1 or boardPlayer == 2) then
                        snapshot.integritySignature.commandants[boardPlayer] = (snapshot.integritySignature.commandants[boardPlayer] or 0) + 1
                    end
                end
            end
        end

        snapshot.gridSetupComplete = copySerializable(self.currentGrid.setupComplete)
    end

    return snapshot
end

function gameRuler:loadResumeSnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return false, "invalid_snapshot"
    end

    if tonumber(snapshot.version) ~= 4 then
        return false, "unsupported_snapshot_version"
    end

    if not self.currentGrid then
        return false, "missing_grid"
    end

    local grid = self.currentGrid

    local function inferCommandantPlayer(row, col)
        for factionId = 1, 2 do
            local hubPos = self.commandHubPositions and self.commandHubPositions[factionId]
            if hubPos and tonumber(hubPos.row) == row and tonumber(hubPos.col) == col then
                return factionId
            end
        end

        if row and grid.rows then
            local mid = math.floor((tonumber(grid.rows) or 8) / 2)
            if row <= mid then
                return 1
            end
            return 2
        end

        return nil
    end

    local function rehydrateUnitFromSnapshot(unitState, fallbackPlayer, isSupply, rowHint, colHint)
        if type(unitState) ~= "table" then
            return nil
        end

        local unitName = unitState.name and tostring(unitState.name) or nil
        if not unitName or unitName == "" then
            return nil
        end

        local template = unitsInfo:getUnitInfo(unitName)
        if not template then
            return nil
        end

        local unit = {}
        for key, value in pairs(template) do
            unit[key] = value
        end

        local resolvedPlayer = tonumber(unitState.player)
        if resolvedPlayer ~= 1 and resolvedPlayer ~= 2 then
            resolvedPlayer = tonumber(fallbackPlayer)
        end

        if unitName == "Commandant" and (resolvedPlayer ~= 1 and resolvedPlayer ~= 2) then
            resolvedPlayer = inferCommandantPlayer(rowHint, colHint)
        end

        if resolvedPlayer == 1 or resolvedPlayer == 2 then
            unit.player = resolvedPlayer
        end

        local hp = tonumber(unitState.currentHp)
        local maxHp = tonumber(unit.startingHp)
        if hp == nil then
            hp = maxHp or unit.currentHp
        end
        if maxHp then
            hp = math.max(0, math.min(maxHp, hp or maxHp))
        end
        if hp ~= nil then
            unit.currentHp = hp
        end

        if isSupply then
            unit.hasActed = nil
            unit.turnActions = nil
        else
            unit.hasActed = unitState.hasActed == true
            if type(unitState.turnActions) == "table" then
                unit.turnActions = copySerializable(unitState.turnActions) or {}
            else
                unit.turnActions = {}
            end
        end

        unit.isAnimating = nil
        unit.justPlaced = nil
        unit.placedTime = nil
        unit.materializeProgress = nil
        unit.isHologram = nil
        unit.zoomScale = nil

        return unit
    end

    if grid.rows and grid.cols and grid.removeUnit then
        for row = 1, grid.rows do
            for col = 1, grid.cols do
                grid:removeUnit(row, col)
            end
        end
    end

    if type(grid.commandHubs) == "table" then
        grid.commandHubs = {}
    end

    self.currentPhase = snapshot.currentPhase or self.currentPhase
    self.currentTurnPhase = snapshot.currentTurnPhase or self.currentTurnPhase
    self.currentTurn = tonumber(snapshot.currentTurn) or self.currentTurn or 0
    self.currentPlayer = tonumber(snapshot.currentPlayer) or self.currentPlayer or 1
    self.turnOrder = copySerializable(snapshot.turnOrder) or self.turnOrder or {1, 2}
    self.factionAssignments = copySerializable(snapshot.factionAssignments) or self.factionAssignments or {}
    self.winner = snapshot.winner
    self.maxActionsPerTurn = tonumber(snapshot.maxActionsPerTurn) or self.maxActionsPerTurn
    self.currentTurnActions = tonumber(snapshot.currentTurnActions) or 0
    self.hasDeployedThisTurn = snapshot.hasDeployedThisTurn == true
    self.commandHubPositions = copySerializable(snapshot.commandHubPositions) or {}
    self.tempCommandHubPosition = copySerializable(snapshot.tempCommandHubPosition) or {}
    self.commandHubPlacementReady = snapshot.commandHubPlacementReady == true

    self.playerSupplies = { [1] = {}, [2] = {} }
    for factionId = 1, 2 do
        local supplyStates = snapshot.playerSupplies and snapshot.playerSupplies[factionId] or {}
        for _, supplyState in ipairs(supplyStates or {}) do
            local unit = rehydrateUnitFromSnapshot(supplyState, factionId, true)
            if unit then
                self.playerSupplies[factionId][#self.playerSupplies[factionId] + 1] = unit
            end
        end
    end
    self.player1Supply = self.playerSupplies[1]
    self.player2Supply = self.playerSupplies[2]

    self.initialDeployment = {
        requiredDeployments = snapshot.initialDeployment and (tonumber(snapshot.initialDeployment.requiredDeployments) or (INITIAL_DEPLOY_RULES.COUNT or 1)) or (INITIAL_DEPLOY_RULES.COUNT or 1),
        completedDeployments = snapshot.initialDeployment and (tonumber(snapshot.initialDeployment.completedDeployments) or 0) or 0,
        availableCells = copySerializable(snapshot.initialDeployment and snapshot.initialDeployment.availableCells or {}),
        selectedUnitIndex = snapshot.initialDeployment and snapshot.initialDeployment.selectedUnitIndex or nil
    }

    self.turnsWithoutDamage = tonumber(snapshot.turnsWithoutDamage) or 0
    self.turnHadInteraction = snapshot.turnHadInteraction == true
    self.drawGame = snapshot.drawGame == true
    self.onlineDrawOfferPending = false
    self.noMoreUnitsGameOver = snapshot.noMoreUnitsGameOver == true
    self.logicRngSeed = tonumber(snapshot.logicRngSeed) or self.logicRngSeed
    self.logicRngState = tonumber(snapshot.logicRngState) or self.logicRngState
    self.neutralBuildings = copySerializable(snapshot.neutralBuildings) or {}
    self.neutralBuildingsPlaced = tonumber(snapshot.neutralBuildingsPlaced) or 0
    self.targetRows = copySerializable(snapshot.targetRows) or (OBSTACLE_RULES.ROWS or {3, 4, 5, 6})
    self.usedRows = copySerializable(snapshot.usedRows) or {}
    self.actionsPhaseSupplySelection = snapshot.actionsPhaseSupplySelection

    self.currentUnit = nil
    self.currentTarget = nil
    self.currentActionPreview = nil
    self.scheduledActions = {}

    local expectedBoardUnits = 0
    local placedBoardUnits = 0
    local commandantCounts = { [1] = 0, [2] = 0 }
    for _, entry in ipairs(snapshot.boardUnits or {}) do
        local row = tonumber(entry.row)
        local col = tonumber(entry.col)
        if row and col then
            expectedBoardUnits = expectedBoardUnits + 1
            local fallbackPlayer = entry.name == "Commandant" and inferCommandantPlayer(row, col) or nil
            local unit = rehydrateUnitFromSnapshot(entry, fallbackPlayer, false, row, col)
            if unit and grid:placeUnit(unit, row, col) then
                placedBoardUnits = placedBoardUnits + 1
                if unit.name == "Commandant" and (unit.player == 1 or unit.player == 2) then
                    commandantCounts[unit.player] = (commandantCounts[unit.player] or 0) + 1
                end
            else
                print(string.format("[Resume] Failed to place unit '%s' at %s,%s", tostring(entry.name), tostring(row), tostring(col)))
            end
        end
    end

    if expectedBoardUnits ~= placedBoardUnits then
        self:resetGame()
        return false, string.format("board_unit_count_mismatch:%d/%d", placedBoardUnits, expectedBoardUnits)
    end

    local blueCommandants = commandantCounts[1] or 0
    local redCommandants = commandantCounts[2] or 0
    if self:isScenarioMode() then
        if blueCommandants ~= 0 or redCommandants ~= 1 then
            self:resetGame()
            return false, string.format("commandant_integrity_failed:%d/%d", blueCommandants, redCommandants)
        end
    elseif blueCommandants ~= 1 or redCommandants ~= 1 then
        self:resetGame()
        return false, string.format("commandant_integrity_failed:%d/%d", blueCommandants, redCommandants)
    end

    local expectedSignature = snapshot.integritySignature
    if type(expectedSignature) == "table" then
        local actualSignature = {
            boardUnitTotal = 0,
            boardByPlayer = { [0] = 0, [1] = 0, [2] = 0 },
            supplyByPlayer = { [1] = 0, [2] = 0 },
            commandants = { [1] = 0, [2] = 0 }
        }

        if grid.rows and grid.cols then
            for row = 1, grid.rows do
                for col = 1, grid.cols do
                    local unit = grid:getUnitAt(row, col)
                    if unit then
                        actualSignature.boardUnitTotal = actualSignature.boardUnitTotal + 1
                        local player = tonumber(unit.player)
                        if player ~= 0 and player ~= 1 and player ~= 2 then
                            player = 0
                        end
                        actualSignature.boardByPlayer[player] = (actualSignature.boardByPlayer[player] or 0) + 1
                        if unit.name == "Commandant" and (player == 1 or player == 2) then
                            actualSignature.commandants[player] = (actualSignature.commandants[player] or 0) + 1
                        end
                    end
                end
            end
        end

        for factionId = 1, 2 do
            actualSignature.supplyByPlayer[factionId] = #(self.playerSupplies[factionId] or {})
        end

        local mismatch = false
        local function valuesEqual(expected, actual)
            return tonumber(expected or 0) == tonumber(actual or 0)
        end

        mismatch = mismatch or not valuesEqual(expectedSignature.boardUnitTotal, actualSignature.boardUnitTotal)
        for _, player in ipairs({0, 1, 2}) do
            mismatch = mismatch or not valuesEqual(
                expectedSignature.boardByPlayer and expectedSignature.boardByPlayer[player],
                actualSignature.boardByPlayer[player]
            )
        end
        for _, player in ipairs({1, 2}) do
            mismatch = mismatch or not valuesEqual(
                expectedSignature.supplyByPlayer and expectedSignature.supplyByPlayer[player],
                actualSignature.supplyByPlayer[player]
            )
            mismatch = mismatch or not valuesEqual(
                expectedSignature.commandants and expectedSignature.commandants[player],
                actualSignature.commandants[player]
            )
        end

        if mismatch then
            self:resetGame()
            return false, "integrity_signature_mismatch"
        end
    end

    if type(snapshot.gridSetupComplete) == "table" then
        grid.setupComplete = copySerializable(snapshot.gridSetupComplete)
    end

    if grid.clearHighlightedCells then
        grid:clearHighlightedCells()
    end
    if grid.clearForcedHighlightedCells then
        grid:clearForcedHighlightedCells()
    end
    if grid.clearActionHighlights then
        grid:clearActionHighlights()
    end
    if grid.clearSelectedGridUnit then
        grid:clearSelectedGridUnit()
    end

    self:updateGridHighlights()
    return true
end

--------------------------------------------------
-- ACTION HANDLERS
--------------------------------------------------
function gameRuler:scheduleAction(delay, callback)
    table.insert(self.scheduledActions, {
        timeRemaining = delay,
        callback = callback
    })
end

function gameRuler:hasActiveAnimations()
    if not self.currentGrid or not self.currentGrid.hasActiveAnimations then
        return false
    end

    return self.currentGrid:hasActiveAnimations()
end

function gameRuler:updateScheduledActions(dt)
    -- Update game timer if it's running
    if self.gameTimer and self.gameTimer.isRunning then
        self.gameTimer.currentTime = love.timer.getTime()
        self.gameTimer.runningDuration = self.gameTimer.currentTime - self.gameTimer.startTime
    end

    if not self.scheduledActions then return end

    -- Process backwards to allow safe removal
    for i = #self.scheduledActions, 1, -1 do
        local action = self.scheduledActions[i]
        action.timeRemaining = action.timeRemaining - dt

        if action.timeRemaining <= 0 then
            -- Time's up, execute the callback
            action.callback()
            -- Remove this action
            table.remove(self.scheduledActions, i)
        end
    end
end

function gameRuler:checkTurnCompletion()
    -- Check action limit first
    if self:areActionsComplete() then
        return true -- Turn is complete
    end
    
    -- Check if all units have acted
    local totalUnits = 0
    local actedUnits = 0
    
    for row = 1, self.currentGrid.rows do
        for col = 1, self.currentGrid.cols do
            local unit = self.currentGrid:getUnitAt(row, col)
            if unit and unit.player == self.currentPlayer and unit.name ~= "Commandant" then
                totalUnits = totalUnits + 1
                if unit.hasActed then
                    actedUnits = actedUnits + 1
                end
            end
        end
    end
    
    -- If all units have acted, force turn completion
    if totalUnits > 0 and actedUnits >= totalUnits then
        self.currentTurnActions = self.maxActionsPerTurn
        return true
    end
    
    return false
end

function gameRuler:previewUnitMovement(row, col)
    if self:areActionsComplete() then
        return false
    end

    if not self:canUnitPerformAction(row, col, "move") then
        return false
    end

    self.currentGrid:clearActionHighlights()

    local unit = self.currentGrid:getUnitAt(row, col)

    if not unit or unit.player ~= self.currentPlayer then
        return false
    end

    if unit.hasActed then
        return false
    end

    -- Store movement options
    local moveCells = {}

    -- Get unit's movement range using centralized function with debug printing
    local movementRange = unitsInfo:getUnitMoveRange(unit, "GAME_RULER_GET_MOVE_PREVIEW")

    -- Use orthogonal directions only (up, down, left, right)
    local directions = {
        {row = 0, col = 1},  -- Right
        {row = 0, col = -1}, -- Left
        {row = 1, col = 0},  -- Down
        {row = -1, col = 0}  -- Up
    }

    -- For flying units, use a different approach
    if unit.fly then
        -- For each direction, check all cells within movement range
        for _, dir in ipairs(directions) do
            for dist = 1, movementRange do
                local r = row + (dir.row * dist)
                local c = col + (dir.col * dist)

                -- Check if position is valid
                if self.currentGrid:isValidPosition(r, c) then
                    -- Flying units can move to ANY empty cell within range
                    -- regardless of what's between the start and destination
                    if self.currentGrid:isCellEmpty(r, c) then
                        table.insert(moveCells, { row = r, col = c })
                    end
                    -- Note: We DON'T break on Rocks for flying units
                else
                    -- Out of bounds, stop checking this direction
                    break
                end
            end
        end
    else
        -- Original movement logic for non-flying units
        for _, dir in ipairs(directions) do
            for dist = 1, movementRange do
                local r = row + (dir.row * dist)
                local c = col + (dir.col * dist)

                -- Check if position is valid
                if self.currentGrid:isValidPosition(r, c) then
                    -- If the cell is empty, it's a valid move
                    if self.currentGrid:isCellEmpty(r, c) then
                        table.insert(moveCells, { row = r, col = c })
                    else
                        -- Stop at Rocks - can't move through units
                        break
                    end
                else
                    -- Out of bounds, stop checking this direction
                    break
                end
            end
        end
    end

    -- Initialize if nil
    if not self.currentActionPreview then
        self.currentActionPreview = {}
    end

    self.currentActionPreview.selectedUnit = {
        row = row,
        col = col,
        unit = unit
    }
    self.currentActionPreview.moveCells = moveCells

    -- Highlight the cells
    if #moveCells > 0 then
        self.currentGrid:forceShowMovementCells(moveCells)
    end

    if self.currentActionPreview and self.currentActionPreview.moveCells then
        for _, cell in ipairs(self.currentActionPreview.moveCells) do
            self.currentGrid:setCellActionHighlight(cell.row, cell.col, "move")
        end
    end

    return true
end

function gameRuler:getOpponentPlayer()
    return 3 - self.currentPlayer
end

-- Preview attack range for a unit
function gameRuler:previewUnitAttack(row, col)

    if self:areActionsComplete() then
        return false
    end

    if not self:canUnitPerformAction(row, col, "attack") then
        return false
    end

    self.currentGrid:clearActionHighlights()

    -- Get the unit at this position
    local unit = self.currentGrid:getUnitAt(row, col)
    if not unit or unit.player ~= self.currentPlayer then
        return false
    end

    if unit.hasActed then
        return false
    end

    -- BLOCK Commandant ATTACK PREVIEWS - Commandants cannot attack
    if unit.name == "Commandant" then
        return false
    end

    -- Get the unit's attack range using centralized function with debug printing
    local attackRange = unitsInfo:getUnitAttackRange(unit, "GAME_RULER_GET_ATTACK_PREVIEW")

    -- Store valid attack target cells
    local attackCells = {}

    -- Use orthogonal directions only (up, down, left, right)
    local directions = {
        {row = 0, col = 1},  -- Right
        {row = 0, col = -1}, -- Left
        {row = 1, col = 0},  -- Down
        {row = -1, col = 0}  -- Up
    }

    -- Special handling for units with attack restrictions
    local isCorvette = (unit.name == "Cloudstriker")
    local isArtillery = (unit.name == "Artillery")

    -- For each direction, check for enemy targets within attack range
    for _, dir in ipairs(directions) do
        -- For Corvette, first check if an adjacent unit is blocking line of sight
        local isBlocked = false

        if isCorvette then
            -- Check adjacent cell first (distance = 1)
            local adjRow = row + dir.row
            local adjCol = col + dir.col

            if self.currentGrid:isValidPosition(adjRow, adjCol) then
                -- If there's any unit in the adjacent cell, the Corvette is blocked in this direction
                if self.currentGrid:getUnitAt(adjRow, adjCol) then
                    isBlocked = true
                end
            end
        end
        -- Artillery doesn't need line of sight checks (can shoot through Rocks)

        -- Special handling for Corvette and Artillery - can't attack adjacent cells
        local minRange = 1
        if isCorvette or isArtillery then
            minRange = 2  -- Start from range 2 (skip adjacent)
        end

        -- Only check further cells if not blocked
        if not isBlocked then
            -- Check each position in this direction
            for dist = minRange, attackRange do
                local r = row + (dir.row * dist)
                local c = col + (dir.col * dist)

                -- Check if position is valid
                if self.currentGrid:isValidPosition(r, c) then
                    -- Check if there's a unit at this position
                    local targetUnit = self.currentGrid:getUnitAt(r, c)

                    if targetUnit then
                        -- If it's an enemy unit, it's a valid attack target
                        if targetUnit.player ~= self.currentPlayer then
                            table.insert(attackCells, {row = r, col = c})
                        end

                        -- Artillery can shoot over/through EVERYTHING - never blocked
                        if not isArtillery then
                            -- For non-Artillery units: stop when we hit ANY unit (proper line-of-sight blocking)
                            break
                        else
                            -- Artillery NEVER stops - can shoot over/through units, buildings, Commandants
                            -- Artillery continues through everything - nothing blocks Artillery attacks
                        end
                    end
                else
                    -- Out of bounds, stop checking this direction
                    break
                end
            end
        end
    end

    -- Initialize if nil
    if not self.currentActionPreview then
        self.currentActionPreview = {}
    end

    -- Set selectedUnit and add attackCells without replacing other cell types
    self.currentActionPreview.selectedUnit = {
        row = row,
        col = col,
        unit = unit
    }
    self.currentActionPreview.attackCells = attackCells

    -- Highlight valid attack cells
    if #attackCells > 0 then
        self.currentGrid:forceShowAttackCells(attackCells)
    end

    return true
end

function gameRuler:previewUnitRepair(row, col)

    if self:areActionsComplete() then
        return false
    end

    if not self:canUnitPerformAction(row, col, "repair") then
        return false
    end

    self.currentGrid:clearActionHighlights()

    -- Get the unit at this position
    local unit = self.currentGrid:getUnitAt(row, col)
    if not unit or unit.player ~= self.currentPlayer then
        return false
    end

    if unit.hasActed then
        return false
    end

    -- Check if this unit has repair capability using the "repair" property
    if not unit.repair then
        return false
    end

    -- Get the unit's repair range (default to 1)
    local repairRange = unit.repairRange or 1

    -- Store valid repair target cells
    local repairCells = {}

    -- Use orthogonal directions only (up, down, left, right)
    local directions = {
        {row = 0, col = 1},  -- Right
        {row = 0, col = -1}, -- Left
        {row = 1, col = 0},  -- Down
        {row = -1, col = 0}  -- Up
    }

    -- For each direction, check for friendly units within range
    for _, dir in ipairs(directions) do
        for dist = 1, repairRange do
            local r = row + (dir.row * dist)
            local c = col + (dir.col * dist)

            -- Check if position is valid
            if self.currentGrid:isValidPosition(r, c) then
                -- Check if there's a unit at this position
                local targetUnit = self.currentGrid:getUnitAt(r, c)

                -- If there's a unit, check if it's a valid repair target
                if targetUnit then
                    -- Allow repairing ANY friendly unit, regardless of health
                    -- This lets players choose to waste an action if they want
                    if targetUnit.player == self.currentPlayer then
                        table.insert(repairCells, {row = r, col = c})
                    end

                    -- Stop at any unit (can't repair through units)
                    break
                end
            else
                -- Out of bounds, stop checking this direction
                break
            end
        end
    end

    -- Initialize if nil
    if not self.currentActionPreview then
        self.currentActionPreview = {}
    end

    self.currentActionPreview.selectedUnit = {
        row = row,
        col = col,
        unit = unit
    }
    self.currentActionPreview.repairCells = repairCells

    -- Show repair cells on grid
    if #repairCells > 0 then
        self.currentGrid:forceShowRepairCells(repairCells)
    end

    return true
end

function gameRuler:recalculateMaxActions()
    local unitCount = self:countCurrentPlayerUnits()
    
    -- Calculate how many actions are actually possible this turn
    local possibleActions = self:calculatePossibleActions()
    
    -- Always enforce exactly 2 actions maximum per turn (fixed rule)
    self.maxActionsPerTurn = TURN_RULES.ACTIONS_PER_TURN or GAME.CONSTANTS.MAX_ACTIONS_PER_TURN
    
    -- If no actions are possible, mark turn as complete
    if possibleActions == 0 then
        self.currentTurnActions = self.maxActionsPerTurn
    end
    
    return unitCount
end

-- Calculate how many actions are actually possible this turn
function gameRuler:calculatePossibleActions()
    -- Prevent infinite recalculation loops
    if self.isRecalculatingActions then
        return self.lastCalculatedActions or 0
    end
    
    self.isRecalculatingActions = true
    local possibleActions = 0
    
    -- Check if deployment is possible (counts as 1 action)
    local canDeploy = self:canDeployInActionsPhase()
    if canDeploy then
        possibleActions = possibleActions + 1
    end
    
    -- Count actual available actions for each unit
    local totalUnitActions = 0
    local actionableUnits = 0
    
    for row = 1, 8 do
        for col = 1, 8 do
            local unit = self.currentGrid:getUnitAt(row, col)
            if unit and unit.player == self.currentPlayer and unit.name ~= "Commandant" and unit.name ~= "Rock" then
                local unitActions = self:calculateUnitPossibleActions(unit, row, col)
                if unitActions > 0 then
                    actionableUnits = actionableUnits + 1
                    totalUnitActions = totalUnitActions + unitActions
                end
            end
        end
    end
    
    possibleActions = possibleActions + totalUnitActions
    
    -- Cache result and clear recalculation flag
    self.lastCalculatedActions = math.max(0, possibleActions)
    self.isRecalculatingActions = false
    
    return self.lastCalculatedActions
end

-- Calculate how many actions a specific unit can perform
function gameRuler:calculateUnitPossibleActions(unit, row, col)
    if not unit or unit.hasActed then
        return 0 -- Unit already acted this turn
    end

    local actions = 0

    -- Check if unit can move (if hasn't moved yet)
    if not unit.hasMoved then
        local canMove = self:unitHasValidMoves(row, col)
        if canMove then
            actions = actions + 1
        end
    end

    -- Check if unit can attack
    local canAttack = self:unitHasValidAttacks(row, col)
    if canAttack then
        actions = actions + 1
    end

    -- Check if unit can repair (for Healers)
    if unit.name == "Healer" then
        local canRepair = self:unitHasValidRepairs(row, col)
        if canRepair then
            actions = actions + 1
        end
    end

    -- Cap at 2 actions max per unit (move + attack/repair)
    return math.min(actions, 2)
end

-- Get a list of available actions for display
function gameRuler:getAvailableActionsList()
    local actions = {}

    -- Check for deployment
    if self:canDeployInActionsPhase() then
        table.insert(actions, "DEPLOY")
    end

    -- Check what unit actions are available
    local canMove = false
    local canAttack = false
    local canRepair = false

    for row = 1, 8 do
        for col = 1, 8 do
            local unit = self.currentGrid:getUnitAt(row, col)
            if unit and unit.player == self.currentPlayer and unit.name ~= "Commandant" and unit.name ~= "Rock" and not unit.hasActed then
                -- Check movement (only if unit hasn't moved yet)
                if not unit.turnActions or not unit.turnActions["move"] then
                    if self:unitHasValidMoves(row, col) then
                        canMove = true
                    end
                end

                -- Check attack
                if self:unitHasValidAttacks(row, col) then
                    canAttack = true
                end

                -- Check repair
                if unit.name == "Healer" and self:unitHasValidRepairs(row, col) then
                    canRepair = true
                end
            end
        end
    end

    -- Add unit actions to the list
    if canMove then
        table.insert(actions, "MOVE")
    end
    if canAttack then
        table.insert(actions, "STRIKE")
    end
    if canRepair then
        table.insert(actions, "REPAIR")
    end

    -- Format the actions list
    if #actions == 0 then
        return "No actions available."
    elseif #actions == 1 then
        return "We can " .. actions[1] .. "."
    elseif #actions == 2 then
        return "We can " .. actions[1] .. " or " .. actions[2] .. "."
    else
        local result = ""
        for i = 1, #actions - 1 do
            result = result .. actions[i] .. ", "
        end
        result = "We can " .. result .. "or " .. actions[#actions] .. "."
        return result
    end
end

-- Helper: Check if unit has valid moves
function gameRuler:unitHasValidMoves(row, col)
    local unit = self.currentGrid:getUnitAt(row, col)
    if not unit then 
        return false 
    end

    -- Check if unit has already moved using the turnActions system
    if unit.turnActions and unit.turnActions["move"] then
        return false
    end

    -- Quick check: try adjacent cells
    local directions = {{-1,0}, {1,0}, {0,-1}, {0,1}}
    for _, dir in ipairs(directions) do
        local newRow, newCol = row + dir[1], col + dir[2]
        if newRow >= 1 and newRow <= 8 and newCol >= 1 and newCol <= 8 then
            if self.currentGrid:isCellEmpty(newRow, newCol) then
                return true -- At least one valid move found
            end
        end
    end
    return false
end

function gameRuler:isLegalAttackTarget(fromRow, fromCol, targetRow, targetCol, opts)
    opts = opts or {}

    local attacker = opts.attackingUnit or self.currentGrid:getUnitAt(fromRow, fromCol)
    if not attacker then
        return false
    end

    if not opts.skipActionAvailability then
        if not self:canUnitPerformAction(fromRow, fromCol, "attack") then
            return false
        end
    end

    local targetUnit = self.currentGrid:getUnitAt(targetRow, targetCol)
    if not targetUnit then
        return false
    end

    if targetUnit.player == attacker.player then
        return false
    end

    local rowDiff = math.abs(targetRow - fromRow)
    local colDiff = math.abs(targetCol - fromCol)
    local distance = rowDiff + colDiff

    local attackRange = unitsInfo:getUnitAttackRange(attacker, "LEGAL_ATTACK_TARGET_CHECK")
    local isCloudstriker = attacker.name == "Cloudstriker"
    local isArtillery = attacker.name == "Artillery"
    local minRange = (isCloudstriker or isArtillery) and 2 or 1

    if distance < minRange or distance > attackRange then
        return false
    end

    if isArtillery then
        local isOrthogonal = (rowDiff == 0 and colDiff > 0) or (colDiff == 0 and rowDiff > 0)
        if not isOrthogonal then
            return false
        end
        return true
    end

    if isCloudstriker then
        return self:hasLineOfSight({row = fromRow, col = fromCol}, {row = targetRow, col = targetCol}, attacker)
    end

    return true
end

-- Helper: Check if unit has valid attacks
function gameRuler:unitHasValidAttacks(row, col)
    local unit = self.currentGrid:getUnitAt(row, col)
    if not unit then return false end

    if not self:canUnitPerformAction(row, col, "attack") then
        return false
    end

    local attackRange = unitsInfo:getUnitAttackRange(unit, "UNIT_HAS_VALID_ATTACKS")
    local rowMin = math.max(1, row - attackRange)
    local rowMax = math.min(8, row + attackRange)
    local colMin = math.max(1, col - attackRange)
    local colMax = math.min(8, col + attackRange)

    for targetRow = rowMin, rowMax do
        for targetCol = colMin, colMax do
            if not (targetRow == row and targetCol == col) then
                if self:isLegalAttackTarget(row, col, targetRow, targetCol, {
                    attackingUnit = unit,
                    skipActionAvailability = true
                }) then
                    return true
                end
            end
        end
    end

    return false
end

-- Helper: Check if unit has valid repairs
function gameRuler:unitHasValidRepairs(row, col)
    local unit = self.currentGrid:getUnitAt(row, col)
    if not unit or unit.name ~= "Healer" then return false end

    -- Check adjacent cells for any friendly units (repair works on both damaged and full HP units)
    local directions = {{-1,0}, {1,0}, {0,-1}, {0,1}}
    for _, dir in ipairs(directions) do
        local targetRow, targetCol = row + dir[1], col + dir[2]
        if targetRow >= 1 and targetRow <= 8 and targetCol >= 1 and targetCol <= 8 then
            local target = self.currentGrid:getUnitAt(targetRow, targetCol)
            if target and target.player == self.currentPlayer and target.name ~= "Rock" then
                return true -- Found friendly unit that can be repaired
            end
        end
    end
    return false
end

-- Execute unit movement action
function gameRuler:executeUnitMovement(fromRow, fromCol, toRow, toCol, isConquerMove)
    local isConquerAction = isConquerMove or false

    -- Check if unit can perform move action
    if not isConquerAction and not self:canUnitPerformAction(fromRow, fromCol, "move") then
        return false
    end

    local unit = self.currentGrid:getUnitAt(fromRow, fromCol)
    if not unit then return false end

    -- Validate destination
    if not self.currentGrid:isValidPosition(toRow, toCol) or not self.currentGrid:isCellEmpty(toRow, toCol) then
        return false
    end

    -- Play move action start sound
    if SETTINGS.AUDIO.SFX then
        soundCache.play("assets/audio/SwooshSlide1b.wav", {
            volume = SETTINGS.AUDIO.SFX_VOLUME * 0.4
        })
    end

    -- Count the global action
    if not isConquerAction then
        self.currentTurnActions = (self.currentTurnActions or 0) + 1
        -- Record the move action but DON'T mark as acted
        self:recordUnitAction(fromRow, fromCol, "move")
    end

    -- Create unit data copy for animation
    local unitData = {}
    for k, v in pairs(unit) do
        unitData[k] = v
    end

    unit.isAnimating = true

    -- Start animation
    local anim
    if GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and self.currentPlayer == GAME.CURRENT.AI_PLAYER_NUMBER then
        anim = self.currentGrid:startAiMovementAnimation(fromRow, fromCol, toRow, toCol, unitData, 1.0, nil, false, 0.2, true, true, "move")
    else
        anim = self.currentGrid:startMovementAnimation(fromRow, fromCol, toRow, toCol, unitData, 1.0, nil, false, nil, false)
    end

    if not isConquerAction then
        self:addLogEntry(self.currentPlayer, "Moved " .. unit.shortName .. " from", fromRow, fromCol, "to " .. self:gridToChessNotation(toRow, toCol))
    else
        if self.currentPhase ~= PHASES.GAME_OVER then
            self:addLogEntry(self.currentPlayer, unit.shortName .. " conquered " .. self:gridToChessNotation(toRow, toCol))
        end
    end

    -- Animation completion
    anim.onComplete = function()
        -- HERE
        self.currentGrid:clearActionHighlights()
        self.currentGrid:removeUnit(fromRow, fromCol)
        unitData.isAnimating = nil

        -- For conquer moves, mark as acted
        if isConquerAction then
            unitData.hasActed = true
        end

        self.currentGrid:placeUnit(unitData, toRow, toCol)

        if not isConquerAction then
            self:checkForStalledUnits()
        end
    end

    return true
end

function gameRuler:executeUnitAttack(fromRow, fromCol, targetRow, targetCol)
    -- Check if unit can perform attack action
    if not self:canUnitPerformAction(fromRow, fromCol, "attack") then
        return false
    end

    -- Get the attacking unit
    local attackingUnit = self.currentGrid:getUnitAt(fromRow, fromCol)
    if not attackingUnit or attackingUnit.player ~= self.currentPlayer then
        return false
    end

    -- Get the target unit
    local targetUnit = self.currentGrid:getUnitAt(targetRow, targetCol)
    if not targetUnit or targetUnit.player == self.currentPlayer then
        return false
    end

    -- Artillery can ONLY attack orthogonally (no diagonal attacks)
    if attackingUnit.name == "Artillery" then
        local rowDiff = math.abs(targetRow - fromRow)
        local colDiff = math.abs(targetCol - fromCol)
        local isOrthogonal = (rowDiff == 0 and colDiff > 0) or (colDiff == 0 and rowDiff > 0)
        
        if not isOrthogonal then
            return false
        end
    end

    if DRAW_RULES.RESET_ON_ANY_ATTACK ~= false then
        self:resetNoInteractionCounter("unit_attack")
    end

    -- Count global action and mark unit as acted (attack ends unit's turn)
    self.currentTurnActions = (self.currentTurnActions or 0) + 1
    self:recordUnitAction(fromRow, fromCol, "attack") -- This will mark hasActed = true
    
    -- Note: Do not recalculate max actions mid-turn as it violates action limit consistency
    

    self:addLogEntry(
        self.currentPlayer,
        attackingUnit.shortName .. " in",
        fromRow, fromCol,
        "attack " .. targetUnit.shortName .. " in " .. self:gridToChessNotation(targetRow, targetCol)
    )

    -- Calculate distance to determine if it's melee
    local distance = math.abs(fromRow - targetRow) + math.abs(fromCol - targetCol)
    local isMeleeAttack = (distance == 1)

    -- For melee attacks, do animation
    if isMeleeAttack then
        local attackingDamage = self:calculateDamage(attackingUnit, targetUnit)
        
        -- Ensure currentHp is initialized
        if not targetUnit.currentHp then
            targetUnit.currentHp = targetUnit.startingHp
        end
        
        -- Apply damage to target
        targetUnit.currentHp = targetUnit.currentHp - attackingDamage

        -- Update damage stats
        self.gameStats.players[self.currentPlayer].damageDealt = self.gameStats.players[self.currentPlayer].damageDealt + attackingDamage

        -- Only update damage taken for actual players (not neutrals)
                local targetPlayer = tonumber(targetUnit.player) or 0
                if targetPlayer > 0 then
                    self.gameStats.players[targetPlayer].damageTaken = self.gameStats.players[targetPlayer].damageTaken + attackingDamage
                end

                -- Similarly for unit destruction
                if targetUnit.currentHp <= 0 then
                    self.gameStats.players[self.currentPlayer].unitsDestroyed = self.gameStats.players[self.currentPlayer].unitsDestroyed + 1

                    -- Only count losses for actual players
                    if targetPlayer > 0 then
                        self.gameStats.players[targetPlayer].unitsLost = self.gameStats.players[targetPlayer].unitsLost + 1
                    end

            if targetPlayer == 0 and targetUnit.name == "Rock" then
                self.gameStats.neutralBuildingsDestroyed = self.gameStats.neutralBuildingsDestroyed + 1
            end
        end
        
        -- Update unit type stats
        if self.gameStats.unitStats[attackingUnit.name] then
            self.gameStats.unitStats[attackingUnit.name].damageDealt = 
                self.gameStats.unitStats[attackingUnit.name].damageDealt + attackingDamage
        end

        self:addLogEntry(
            self.currentPlayer,
            attackingUnit.shortName .. " in",
            fromRow, fromCol,
            attackingDamage .. " dmg to " .. targetUnit.shortName .. " in " .. self:gridToChessNotation(targetRow, targetCol)
        )

        -- Store unit data for animation
        local unitData = {}
        for k, v in pairs(attackingUnit) do
            unitData[k] = v
        end

        -- Mark original unit as animating (to hide it during animation)
        attackingUnit.isAnimating = true

        -- Calculate exact direction vector
        local rowDiff = targetRow - fromRow
        local colDiff = targetCol - fromCol

        -- Normalize direction vector
        local length = math.sqrt(rowDiff*rowDiff + colDiff*colDiff)
        if length > 0 then
            rowDiff = rowDiff / length
            colDiff = colDiff / length
        end

        -- Calculate consistent lunge position
        local lungeRow = fromRow + (rowDiff * 0.3)
        local lungeCol = fromCol + (colDiff * 0.3)

        -- Store original position for consistent return
        local originalRow = fromRow
        local originalCol = fromCol

        -- Play melee attack sound
        if SETTINGS.AUDIO.SFX then
            soundCache.play("assets/audio/SFX_hit&damage13.wav", {
                volume = SETTINGS.AUDIO.SFX_VOLUME
            })
        end

        -- Make animation with consistent timing
        local forwardAnim = self.currentGrid:startMovementAnimation(fromRow, fromCol, lungeRow, lungeCol, unitData, 3.0, nil, true)

        -- Check if target was destroyed
        local targetDestroyed = false

        -- When forward animation completes, do the backward animation
        forwardAnim.onComplete = function()

            -- Start the backward animation using the EXACT same positions
            local backwardAnim = self.currentGrid:startMovementAnimation(lungeRow, lungeCol, originalRow, originalCol, unitData, 3.0, nil, true)

            self.currentGrid:clearActionHighlights()

            -- Flash target cell for impact effect
            local flashDuration = 0.5 -- Default flash duration
            local flashEffect = self.currentGrid:flashCell(targetRow, targetCol, {190/255, 76/255, 60/255})

            -- Check if target was destroyed
            if targetUnit.currentHp <= 0 then

                self.currentGrid:createDestructionEffect(targetRow, targetCol, targetUnit.playerColor)

                -- Play unit destruction sound
                if SETTINGS.AUDIO.SFX then
                    soundCache.play("assets/audio/SFX_explosion4.wav", {
                        volume = SETTINGS.AUDIO.SFX_VOLUME * 0.8
                    })
                end

                self.currentGrid:addFloatingText(targetRow, targetCol, attackingDamage, false, "assets/audio/Success3.wav")

                self:addLogEntry(
                    self.currentPlayer,
                    attackingUnit.shortName .. " in",
                    fromRow, fromCol,
                    "destroy " .. targetUnit.shortName .. " in " .. self:gridToChessNotation(targetRow, targetCol)
                )

                -- Remove from grid
                self.currentGrid:removeUnit(targetRow, targetCol)
                targetDestroyed = true
            else
                self.currentGrid:addFloatingText(targetRow, targetCol, attackingDamage, false, "assets/audio/Success3.wav")

                self.currentGrid:applyDamageFlash(targetRow, targetCol, 0.1)

                self:addLogEntry(
                    targetUnit.player,
                    targetUnit.shortName .. " in",
                    targetRow, targetCol,
                    "HP " .. targetUnit.currentHp
                )

                if targetUnit.name == "Commandant" then
                    self.gameStats.players[targetUnit.player].commandHubAttacksSurvived = self.gameStats.players[targetUnit.player].commandHubAttacksSurvived + 1
                end
            end

            -- When backward animation completes
            backwardAnim.onComplete = function()
                -- If AI clear movement preview cell
                if GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and self.currentPlayer == GAME.CURRENT.AI_PLAYER_NUMBER then
                    self.currentGrid:clearForcedHighlightedCells()
                end

                -- Mark as having acted
                attackingUnit.isAnimating = nil

                if targetDestroyed then
                    local scenarioOutcomeScheduled = false

                    -- Check if it was a Commandant
                    if targetUnit.name == "Commandant" then
                        if self:isScenarioMode() then
                            -- Scenario: only Red Commandant destruction can end the match in victory.
                            self:scheduleAction(0.3, function()
                                self:evaluateScenarioEndConditions("scenario_melee_commandant_destroy")
                            end)
                            scenarioOutcomeScheduled = true
                        else
                            -- Schedule game over with delay to let animation complete
                            self:scheduleAction(0.3, function()
                                -- Game over
                                self:addLogEntryString("P" .. self.currentPlayer .. " WIN! P" .. self:getOpponentPlayer() .. "CM destroyed")
                                self.winner = attackingUnit.player
                                self.lastVictoryReason = "commandant"
                                self:setPhase(PHASES.GAME_OVER)
                            end)
                        end
                    else
                        -- Instead of immediately capturing, schedule the movement after a delay
                        self:scheduleAction(flashDuration, function()
                            -- Capture the position if the target was destroyed
                            self:executeUnitMovement(fromRow, fromCol, targetRow, targetCol, true)
                        end)
                    end

                    if self:isScenarioMode() then
                        if not scenarioOutcomeScheduled then
                            self:scheduleAction(0.3, function()
                                self:evaluateScenarioEndConditions("scenario_melee_unit_destroy")
                            end)
                        end
                    else
                        -- Check if the target player has any units left
                        if not self:playerHasUnitsLeft(self:getOpponentPlayer()) then
                            -- Schedule game over with delay to let animation complete
                            self:scheduleAction(0.3, function()
                                -- No units left, game over
                                self.winner = self.currentPlayer
                                self.lastVictoryReason = "elimination"
                                self:setPhase(PHASES.GAME_OVER)
                            end)
                            return true
                        end
                    end
                end
                -- Check for stalled units
                self:checkForStalledUnits()
            end
        end
    else
        -- Ranged attack
        local attackType = "default"
        if attackingUnit.name == "Cloudstriker" then
            attackType = "beam"

            -- Create a temporary unit data copy for recoil animation
            local unitData = {}
            for k, v in pairs(attackingUnit) do
                unitData[k] = v
            end

            -- Mark original unit as animating (to hide it during animation)
            attackingUnit.isAnimating = true
            self.currentGrid:applyDamageFlash(targetRow, targetCol, 0.3)

            -- Calculate recoil direction vector (opposite of attack direction)
            local rowDiff = fromRow - targetRow  -- Note reversed direction!
            local colDiff = fromCol - targetCol  -- Note reversed direction!

            -- Normalize direction vector
            local length = math.sqrt(rowDiff*rowDiff + colDiff*colDiff)
            if length > 0 then
                rowDiff = rowDiff / length
                colDiff = colDiff / length
            end

            -- Calculate recoil position with consistent distance
            local recoilRow = fromRow + (rowDiff * 0.4)
            local recoilCol = fromCol + (colDiff * 0.4)

            -- Store original position for consistent return
            local originalRow = fromRow
            local originalCol = fromCol

            -- Create beam effect first so it appears immediately
            local beamEffect = self.currentGrid:createRangedAttackEffect(fromRow, fromCol, targetRow, targetCol, attackType)
            local beamDuration = 0.8  -- Match this with the beam effect duration
            local impactDelay = math.min(beamDuration * 0.55, self:getActionAnimationDelay("attack"))
            local damageResolved = false

            local function resolveBeamDamage()
                if damageResolved then
                    return
                end
                damageResolved = true

                -- Resolve the target again at impact time to avoid stale-reference
                -- damage when turns/animations overlap.
                local impactTarget = self.currentGrid:getUnitAt(targetRow, targetCol)
                if not impactTarget or impactTarget.player == self.currentPlayer then
                    return
                end
                if impactTarget ~= targetUnit then
                    return
                end

                local damage = self:calculateDamage(attackingUnit, impactTarget)

                -- Ensure currentHp is initialized
                if not impactTarget.currentHp then
                    impactTarget.currentHp = impactTarget.startingHp
                end

                -- Apply damage when beam animation would be mostly complete
                impactTarget.currentHp = impactTarget.currentHp - damage

                -- Update damage stats
                self.gameStats.players[self.currentPlayer].damageDealt = self.gameStats.players[self.currentPlayer].damageDealt + damage

                -- Only update damage taken for actual players (not neutrals)
                local impactPlayer = tonumber(impactTarget.player) or 0
                if impactPlayer > 0 then
                    self.gameStats.players[impactPlayer].damageTaken = self.gameStats.players[impactPlayer].damageTaken + damage
                end

                -- Similarly for unit destruction
                if impactTarget.currentHp <= 0 then
                    self.gameStats.players[self.currentPlayer].unitsDestroyed = self.gameStats.players[self.currentPlayer].unitsDestroyed + 1

                    -- Only count losses for actual players
                    if impactPlayer > 0 then
                        self.gameStats.players[impactPlayer].unitsLost = self.gameStats.players[impactPlayer].unitsLost + 1
                    end

                    if impactPlayer == 0 and impactTarget.name == "Rock" then
                        self.gameStats.neutralBuildingsDestroyed = self.gameStats.neutralBuildingsDestroyed + 1
                    end
                end

                -- Update unit type stats
                if self.gameStats.unitStats[attackingUnit.name] then
                    self.gameStats.unitStats[attackingUnit.name].damageDealt = 
                        self.gameStats.unitStats[attackingUnit.name].damageDealt + damage
                end

                self:addLogEntry(
                    self.currentPlayer,
                    attackingUnit.shortName .. " in",
                    fromRow, fromCol,
                    damage .. " dmg to " .. impactTarget.shortName .. " in " .. self:gridToChessNotation(targetRow, targetCol)
                )

                -- Flash the target cell
                self.currentGrid:flashCell(targetRow, targetCol, {190/255, 76/255, 60/255})

                -- Check if target was destroyed
                if impactTarget.currentHp <= 0 then

                    self.currentGrid:createDestructionEffect(targetRow, targetCol, impactTarget.playerColor)
                    
                    -- Play unit destruction sound
                    if SETTINGS.AUDIO.SFX then
                        soundCache.play("assets/audio/SFX_explosion4.wav", {
                            volume = SETTINGS.AUDIO.SFX_VOLUME * 0.8
                        })
                    end

                    self.currentGrid:addFloatingText(targetRow, targetCol, damage, false, "assets/audio/Success3.wav")

                    self:addLogEntry(
                        self.currentPlayer,
                        attackingUnit.shortName .. " in",
                        fromRow, fromCol,
                        "destroy " .. impactTarget.shortName .. " in " .. self:gridToChessNotation(targetRow, targetCol)
                    )

                    -- Remove from grid
                    self.currentGrid:removeUnit(targetRow, targetCol)

                    -- Check if it was a Commandant
                    if impactTarget.name == "Commandant" then
                        if self:isScenarioMode() then
                            self:scheduleAction(0.3, function()
                                self:evaluateScenarioEndConditions("scenario_beam_commandant_destroy")
                            end)
                        else
                            -- Schedule game over with delay to let animation complete
                            self:scheduleAction(0.3, function()
                                -- Game over
                                self:addLogEntryString("P" .. self.currentPlayer .. " WIN! P" .. self:getOpponentPlayer() .. "CM destroyed")
                                self.winner = attackingUnit.player
                                self.lastVictoryReason = "commandant"
                                self:setPhase(PHASES.GAME_OVER)
                            end)
                        end
                        return true
                    end

                    if self:isScenarioMode() then
                        self:scheduleAction(0.3, function()
                            self:evaluateScenarioEndConditions("scenario_beam_unit_destroy")
                        end)
                    else
                        -- Check if the target player has any units left
                        if not self:playerHasUnitsLeft(self:getOpponentPlayer()) then
                            -- Schedule game over with delay to let animation complete
                            self:scheduleAction(0.3, function()
                                -- No units left, game over
                                self.winner = self.currentPlayer
                                self.lastVictoryReason = "elimination"
                                self:setPhase(PHASES.GAME_OVER)
                            end)
                            return true
                        end
                    end
                else
                    self.currentGrid:addFloatingText(targetRow, targetCol, damage, false, "assets/audio/Success3.wav")

                    self:addLogEntry(
                        impactTarget.player,
                        impactTarget.shortName .. " in",
                        targetRow, targetCol,
                        "HP " .. impactTarget.currentHp
                    )

                    if impactTarget.name == "Commandant" and impactPlayer > 0 then
                        self.gameStats.players[impactPlayer].commandHubAttacksSurvived = self.gameStats.players[impactPlayer].commandHubAttacksSurvived + 1
                    end

                    if not impactTarget.corvetteDamageFlag then
                        impactTarget.corvetteDamageFlag = false
                    end

                    impactTarget.corvetteDamageFlag = true


                end

                self:checkForStalledUnits()
            end

            self:scheduleAction(impactDelay, resolveBeamDamage)

            self.currentGrid:clearActionHighlights()

            -- Start the recoil animation (unit gets pushed back)
            local recoilAnim = self.currentGrid:startMovementAnimation(fromRow, fromCol, recoilRow, recoilCol, unitData, 4.0, function()
                -- When recoil animation completes, return to original position with timing that matches beam duration
                local returnAnim = self.currentGrid:startMovementAnimation(recoilRow, recoilCol, originalRow, originalCol, unitData, 0.2, function()
                    -- When return animation completes
                    attackingUnit.isAnimating = nil
                    if not damageResolved then
                        resolveBeamDamage()
                    end
                end, true) -- useLinearMovement = true for return animation
            end, true) -- useLinearMovement = true for recoil animation

        elseif attackingUnit.name == "Artillery" then
            -- Artillery ranged attack with projectile
            attackType = "projectile"
            
            self.currentGrid:clearActionHighlights()
            
            -- Create projectile effect
            local projectileEffect = self.currentGrid:createRangedAttackEffect(fromRow, fromCol, targetRow, targetCol, attackType)
            local projectileDuration = 0.5  -- Match this with the projectile effect duration
            
            -- Add target flash effect when projectile hits (like other attacks)
            self:scheduleAction(projectileDuration * 0.85, function()  -- Flash at 85% when impact starts
                self.currentGrid:applyDamageFlash(targetRow, targetCol, 0.3)
            end)
            
            -- Apply damage after projectile animation completes
            self:scheduleAction(projectileDuration, function()
                -- Clear UI highlights and selection state after attack completes
                self.currentGrid:clearActionHighlights()
                self.currentGrid:clearSelectedGridUnit()
                self.currentGrid:clearForcedHighlightedCells()
                self.currentActionPreview = nil
                
                -- Resolve target at impact time to avoid stale-reference damage.
                local impactTarget = self.currentGrid:getUnitAt(targetRow, targetCol)
                if not impactTarget or impactTarget.player == self.currentPlayer then
                    return
                end
                if impactTarget ~= targetUnit then
                    return
                end

                local damage = self:calculateDamage(attackingUnit, impactTarget)
                
                -- Ensure currentHp is initialized
                if not impactTarget.currentHp then
                    impactTarget.currentHp = impactTarget.startingHp
                end
                
                impactTarget.currentHp = impactTarget.currentHp - damage
                
                -- Set Artillery damage flag for AI reactive flow (same as Corvette flag)
                if impactTarget.currentHp > 0 then  -- Only set flag if unit survives
                    if not impactTarget.artilleryDamageFlag then
                        impactTarget.artilleryDamageFlag = false
                    end
                    
                    impactTarget.artilleryDamageFlag = true
                    
                end
                
                -- Update damage stats
                -- Ensure player stats are initialized
                if not self.gameStats.players[self.currentPlayer] then
                    self.gameStats.players[self.currentPlayer] = {damageDealt = 0, damageTaken = 0, unitsDestroyed = 0, unitsLost = 0, repairPoints = 0, commandHubAttacksSurvived = 0}
                end
                self.gameStats.players[self.currentPlayer].damageDealt = self.gameStats.players[self.currentPlayer].damageDealt + damage
                
                -- Only update damage taken for actual players (not neutrals)
                local impactPlayer = tonumber(impactTarget.player) or 0
                if impactPlayer > 0 then
                    if not self.gameStats.players[impactPlayer] then
                        self.gameStats.players[impactPlayer] = {damageDealt = 0, damageTaken = 0, unitsDestroyed = 0, unitsLost = 0, repairPoints = 0, commandHubAttacksSurvived = 0}
                    end
                    self.gameStats.players[impactPlayer].damageTaken = self.gameStats.players[impactPlayer].damageTaken + damage
                end
                
                -- Similarly for unit destruction
                if impactTarget.currentHp <= 0 then
                    self.gameStats.players[self.currentPlayer].unitsDestroyed = self.gameStats.players[self.currentPlayer].unitsDestroyed + 1
                    
                    -- Only count losses for actual players
                    if impactPlayer > 0 then
                        self.gameStats.players[impactPlayer].unitsLost = self.gameStats.players[impactPlayer].unitsLost + 1
                    end
                    
                    if impactPlayer == 0 and impactTarget.name == "Rock" then
                        self.gameStats.neutralBuildingsDestroyed = self.gameStats.neutralBuildingsDestroyed + 1
                    end
                end
                
                -- Update unit type stats with comprehensive defensive programming
                -- Ensure unitStats table exists
                if not self.gameStats.unitStats then
                    self.gameStats.unitStats = {}
                end
                
                -- Ensure attacking unit stats are initialized (with name validation)
                if attackingUnit and attackingUnit.name then
                    if not self.gameStats.unitStats[attackingUnit.name] then
                        self.gameStats.unitStats[attackingUnit.name] = {damageDealt = 0, damageTaken = 0}
                    end
                    if not self.gameStats.unitStats[attackingUnit.name].damageDealt then
                        self.gameStats.unitStats[attackingUnit.name].damageDealt = 0
                    end
                    self.gameStats.unitStats[attackingUnit.name].damageDealt = self.gameStats.unitStats[attackingUnit.name].damageDealt + damage
                end
                
                -- Ensure target unit stats are initialized (with name validation)
                if impactTarget and impactTarget.name then
                    if not self.gameStats.unitStats[impactTarget.name] then
                        self.gameStats.unitStats[impactTarget.name] = {damageDealt = 0, damageTaken = 0}
                    end
                    if not self.gameStats.unitStats[impactTarget.name].damageTaken then
                        self.gameStats.unitStats[impactTarget.name].damageTaken = 0
                    end
                    self.gameStats.unitStats[impactTarget.name].damageTaken = self.gameStats.unitStats[impactTarget.name].damageTaken + damage
                end
                
                self:addLogEntry(
                    self.currentPlayer,
                    attackingUnit.shortName .. " in",
                    fromRow, fromCol,
                    damage .. " dmg to " .. impactTarget.shortName .. " in " .. self:gridToChessNotation(targetRow, targetCol)
                )
                
                -- Check if target was destroyed
                if impactTarget.currentHp <= 0 then
                    self.currentGrid:createDestructionEffect(targetRow, targetCol, impactTarget.playerColor)
                    
                    -- Play unit destruction sound
                    if SETTINGS.AUDIO.SFX then
                        soundCache.play("assets/audio/SFX_explosion4.wav", {
                            volume = SETTINGS.AUDIO.SFX_VOLUME * 0.8
                        })
                    end
                    
                    self.currentGrid:addFloatingText(targetRow, targetCol, damage, false, "assets/audio/Success3.wav")
                    
                    self:addLogEntry(
                        self.currentPlayer,
                        attackingUnit.shortName .. " in",
                        fromRow, fromCol,
                        "destroy " .. impactTarget.shortName .. " in " .. self:gridToChessNotation(targetRow, targetCol)
                    )
                    
                    -- Remove destroyed unit from grid
                    self.currentGrid:removeUnit(targetRow, targetCol)
                    
                    -- Check for game over conditions
                    if impactTarget.name == "Commandant" then
                        if self:isScenarioMode() then
                            self:scheduleAction(0.3, function()
                                self:evaluateScenarioEndConditions("scenario_artillery_commandant_destroy")
                            end)
                        else
                            -- Schedule game over with delay to let animation complete
                            self:scheduleAction(0.3, function()
                                -- Game over
                                self:addLogEntryString("P" .. self.currentPlayer .. " WIN! P" .. self:getOpponentPlayer() .. "CM destroyed")
                                self.winner = attackingUnit.player
                                self.lastVictoryReason = "commandant"
                                self:setPhase(PHASES.GAME_OVER)
                            end)
                        end
                        return true
                    end
                    
                    if self:isScenarioMode() then
                        self:scheduleAction(0.3, function()
                            self:evaluateScenarioEndConditions("scenario_artillery_unit_destroy")
                        end)
                    else
                        -- Check if the target player has any units left
                        if not self:playerHasUnitsLeft(self:getOpponentPlayer()) then
                            -- Schedule game over with delay to let animation complete
                            self:scheduleAction(0.3, function()
                                -- No units left, game over
                                self.winner = self.currentPlayer
                                self.lastVictoryReason = "elimination"
                                self:setPhase(PHASES.GAME_OVER)
                            end)
                            return true
                        end
                    end
                else
                    self.currentGrid:addFloatingText(targetRow, targetCol, damage, false, "assets/audio/Success3.wav")

                    self:addLogEntry(
                        impactTarget.player,
                        impactTarget.shortName .. " in",
                        targetRow, targetCol,
                        "HP " .. impactTarget.currentHp
                    )
                    
                    if impactTarget.name == "Commandant" and impactPlayer > 0 then
                        self.gameStats.players[impactPlayer].commandHubAttacksSurvived = self.gameStats.players[impactPlayer].commandHubAttacksSurvived + 1
                    end
                end
                
                -- Check for stalled units
                self:checkForStalledUnits()
            end)
        end
    end

    return true
end

function gameRuler:checkForStalledUnits()
    if not self.currentGrid then
        return false
    end

    -- Count total units and stalled units for current player
    local totalUnits = 0
    local stalledUnits = 0
    local activeUnits = 0  -- Units that haven't acted yet

    for row = 1, self.currentGrid.rows do
        for col = 1, self.currentGrid.cols do
            local unit = self.currentGrid:getUnitAt(row, col)
            if unit and unit.player == self.currentPlayer and unit.name ~= "Commandant" then
                totalUnits = totalUnits + 1

                if not unit.hasActed then
                    activeUnits = activeUnits + 1

                    -- Check if this unit has any valid actions
                    if not self:unitHasValidActions(row, col) then
                        stalledUnits = stalledUnits + 1
                    end
                end
            end
        end
    end

    local canDeploy = false

    -- Only check deployment if we haven't already deployed this turn and have actions left
    if not self.hasDeployedThisTurn and not self:areActionsComplete() then
        canDeploy = self:canDeployInActionsPhase()
    end

    -- If all remaining active units are stalled AND player can't deploy, force turn completion
    if activeUnits > 0 and stalledUnits >= activeUnits and not canDeploy then
        -- Force complete the turn by setting actions to maximum
        self.currentTurnActions = self.maxActionsPerTurn

        self:addLogEntryString("All units stalled")

        return true -- Turn was auto-completed
    end

    return false -- Normal operation continues
end

function gameRuler:executeUnitRepair(fromRow, fromCol, targetRow, targetCol)
    -- Check if unit can perform repair action
    if not self:canUnitPerformAction(fromRow, fromCol, "repair") then
        return false
    end

    -- Get the repairing unit
    local repairUnit = self.currentGrid:getUnitAt(fromRow, fromCol)
    if not repairUnit or repairUnit.player ~= self.currentPlayer then
        return false
    end

    -- Get the target unit
    local targetUnit = self.currentGrid:getUnitAt(targetRow, targetCol)
    if not targetUnit or targetUnit.player ~= self.currentPlayer then
        return false
    end

    -- Check if the repairing unit has repair capability
    if not repairUnit.repair then
        return false
    end

    -- Count global action and mark unit as acted (repair ends unit's turn)
    self.currentTurnActions = (self.currentTurnActions or 0) + 1
    self:recordUnitAction(fromRow, fromCol, "repair") -- This will mark hasActed = true
    
    -- Note: Do not recalculate max actions mid-turn as it violates action limit consistency
    

    -- Create a copy of the unit data for animation
    local unitData = {}
    for k, v in pairs(repairUnit) do
        unitData[k] = v
    end

    -- Mark original unit as animating (to hide it during animation)
    repairUnit.isAnimating = true

    -- Calculate lunge distance, ensuring at least a small movement in both directions
    local rowDiff = targetRow - fromRow
    local colDiff = targetCol - fromCol

    -- Ensure at least some movement in the correct direction
    local lungeRow = fromRow
    local lungeCol = fromCol

    -- If there's vertical movement needed
    if rowDiff ~= 0 then
        lungeRow = fromRow + (rowDiff > 0 and 0.2 or -0.2)
    end

    -- If there's horizontal movement needed
    if colDiff ~= 0 then
        lungeCol = fromCol + (colDiff > 0 and 0.2 or -0.2)
    end

    -- Play repair action sound
    if SETTINGS.AUDIO.SFX then
        soundCache.play("assets/audio/LittleSwoosh4.wav", {
            volume = SETTINGS.AUDIO.SFX_VOLUME * 0.5
        })
    end

    -- Start the forward animation (slow lunge forward)
    local forwardAnim = self.currentGrid:startMovementAnimation(fromRow, fromCol, lungeRow, lungeCol, unitData, 3.0, nil, true)

    -- When forward animation completes, do the backward animation
    forwardAnim.onComplete = function()
        -- Apply repair effect when at closest point to target
        local repairAmount = repairUnit.repairStrength or 2

        -- Ensure currentHp is initialized
        if not targetUnit.currentHp then
            targetUnit.currentHp = targetUnit.startingHp
        end

        targetUnit.currentHp = math.min(targetUnit.startingHp, targetUnit.currentHp + repairAmount)

        self.currentGrid:clearActionHighlights()

        -- Flash the target cell
        self.currentGrid:flashCell(targetRow, targetCol, {190/255, 76/255, 60/255})

        self.currentGrid:applyDamageFlash(targetRow, targetCol, 0.1)
        self.currentGrid:addFloatingText(targetRow, targetCol, repairAmount, true, "assets/audio/Success4.wav")

        self:addLogEntry(
            self.currentPlayer,
            repairUnit.shortName .. " in",
            fromRow, fromCol,
            "heal " .. repairAmount .. " HP " .. targetUnit.shortName .. " in " .. self:gridToChessNotation(targetRow, targetCol)
        )

        self.gameStats.players[self.currentPlayer].repairPoints = self.gameStats.players[self.currentPlayer].repairPoints + 1

        -- Start the backward animation (return to original position)
        local backwardAnim = self.currentGrid:startMovementAnimation(lungeRow, lungeCol, fromRow, fromCol, unitData, 3.0, nil, true)

        -- When backward animation completes
        backwardAnim.onComplete = function()
            self:addLogEntry(
                self.currentPlayer,
                targetUnit.shortName .. " in",
                targetRow, targetCol,
                "HP " .. targetUnit.currentHp
            )

            -- If AI clear movement preview cell
            if GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and self.currentPlayer == GAME.CURRENT.AI_PLAYER_NUMBER then
                self.currentGrid:clearForcedHighlightedCells()
            end

            -- Mark as having acted (animation complete)
            repairUnit.isAnimating = nil

            -- Check for stalled units
            self:checkForStalledUnits()
        end
    end

    return true
end

-- Main action dispatcher
function gameRuler:performAction(actionType, params)
    local currentMode = GAME and GAME.CURRENT and GAME.CURRENT.MODE or nil
    if currentMode == GAME.MODE.SCENARIO then
        if actionType == "selectSupplyUnit" or actionType == "deployUnit" or actionType == "deployUnitNearHub" then
            return false, "Supply actions are disabled in scenario mode"
        end
    end

    -- Check if the action is allowed in the current phase
    if not self:isActionAllowed(actionType) then
        return false, "Action not allowed in current phase"
    end

    -- Delegate to specific action handlers
    if actionType == "placeAllNeutralBuildings" then
        return self:placeAllNeutralBuildingsSequence()
    elseif actionType == "placeNeutralBuilding" then
        return self:placeNeutralBuilding(params.row, params.col)

    elseif actionType == "placeCommandHub" then
        return self:placeCommandHub(params.row, params.col)

    elseif actionType == "confirmCommandHub" then
        return self:confirmCommandHub()

    -- Unit deployment phase actions
    elseif actionType == "selectSupplyUnit" then
        return self:selectSupplyUnit(params.unitIndex)

    elseif actionType == "deployUnitNearHub" then
        return self:deployUnitNearHub(params.row, params.col, params.unitIndex)

    elseif actionType == "confirmDeployment" then
        return self:currentPlayerStartingUnitsAllDeployed()

    -- Main game actions
    elseif actionType == "deployUnit" then
        return self:deployUnitInActionsPhase(params.unitIndex, params.row, params.col)

    elseif actionType == "move" then

    elseif actionType == "attack" then

    elseif actionType == "repair" then

    -- Turn phase transitions
    elseif actionType == "endActions" then
       return self:nextTurn()

    elseif actionType == "confirmEndTurn" then
        -- Transition to the next player's turn
        return self:nextTurn()

    end

    return false
end

function gameRuler:placeAllNeutralBuildingsSequence()
    local requiredObstacles = OBSTACLE_RULES.COUNT or self.totalNeutralBuildings or 4
    if #self.neutralBuildings >= requiredObstacles then
        self:setPhase(PHASES.DEPLOY1)
        self.currentPlayer = 1
        return true
    end

    -- **NEW: Set flag to hide the button during placement**
    self.neutralBuildingPlacementInProgress = true

    -- Place buildings with small delays for visual effect
    local buildingsToPlace = requiredObstacles - #self.neutralBuildings
    local delay = 0.5

    for i = 1, buildingsToPlace do
        self:scheduleAction(delay * (i - 1), function()
            self:placeNeutralBuilding(0, 0)

            -- After placing the last building, start Player 1's Commandant phase
            if #self.neutralBuildings >= requiredObstacles then
                self:scheduleAction(0.2, function()
                    self.neutralBuildingPlacementInProgress = false
                    self:setPhase(PHASES.DEPLOY1)
                    self.currentPlayer = 1

                    -- Update grid highlights for Commandant placement
                    self:updateGridHighlights()
                end)
            end
        end)
    end

    return true
end

-- Validate Commandant position before placing
function gameRuler:validateCommandHubPosition(row, col)
    if not self.currentGrid then
        return false
    end

    -- Validate player's deployment zone
    local validZone = self.commandHubsValidPositions[self.currentPlayer]
    if not validZone or row < validZone.min or row > validZone.max then
        return false
    end

    -- Check if position is valid and cell is empty
    if not self.currentGrid:isValidPosition(row, col) then
        return false
    end

    if not self.currentGrid:isCellEmpty(row, col) then
        return false
    end

    return true
end

-- Find and remove any temporary Commandant for current player
function gameRuler:removeTemporaryCommandHub()
    if self.tempCommandHubPosition and self.tempCommandHubPosition[self.currentPlayer] then
        local oldPos = self.tempCommandHubPosition[self.currentPlayer]
        self.currentGrid:removeUnit(oldPos.row, oldPos.col)
    end
end

function gameRuler:placeNeutralBuilding(row, col)
    -- Check if we have a grid reference
    if not self.currentGrid then
        return false
    end

    -- NEW RULE: Place 4 Rocks, one in each row from 3 to 6
    -- Initialize tracking if needed
    if not self.neutralBuildingsPlaced then
        self.neutralBuildingsPlaced = 0
        self.targetRows = OBSTACLE_RULES.ROWS or {3, 4, 5, 6}
        self.usedRows = {}  -- Track which rows we've used
    end

    -- Determine which row to use for this building
    local targetRow
    local maxObstacles = OBSTACLE_RULES.COUNT or self.totalNeutralBuildings or 4
    if self.neutralBuildingsPlaced < maxObstacles then
        -- Get the next available row from our target list
        targetRow = self.targetRows[self.neutralBuildingsPlaced + 1]
    else
        -- We've already placed all required buildings
        return false
    end

    -- Find a random column in the target row
    local maxCol = self.currentGrid.cols or GAME.CONSTANTS.GRID_SIZE
    local attempts = 0
    local maxAttempts = 20
    local finalCol = nil

    -- Try to find a free column in the target row
    while attempts < maxAttempts do
        local randomCol = self:logicRandomInt(1, maxCol)
        
        if self.currentGrid:isValidPosition(targetRow, randomCol) and 
           self.currentGrid:isCellEmpty(targetRow, randomCol) then
            finalCol = randomCol
            break
        end
        
        attempts = attempts + 1
    end

    -- If we couldn't find a free spot, try all columns systematically
    if not finalCol then
        for col = 1, maxCol do
            if self.currentGrid:isValidPosition(targetRow, col) and 
               self.currentGrid:isCellEmpty(targetRow, col) then
                finalCol = col
                break
            end
        end
    end

    -- If still no free spot found, something is wrong
    if not finalCol then
        return false
    end

    -- Use the determined row and column
    row, col = targetRow, finalCol

    -- Create a Rock with row-specific variant
    local neutralBuilding = self:createRandomNeutralBuilding(targetRow)

    -- Initial state: show as hologram for a brief moment
    neutralBuilding.isHologram = true  -- Start as hologram
    neutralBuilding.justPlaced = false -- Don't show materialization yet

    -- Place on grid
    local success = self.currentGrid:placeUnit(neutralBuilding, row, col)
    if not success then
        return false
    end

    -- Track building count
    self.neutralBuildingsPlaced = self.neutralBuildingsPlaced + 1
    table.insert(self.usedRows, row)

    self:scheduleAction(0.02, function()
        -- Check if building still exists (prevent nil errors)
        local buildingAtPosition = self.currentGrid:getUnitAt(row, col)
        if not buildingAtPosition then return end

        -- Remove hologram flag FIRST
        buildingAtPosition.isHologram = nil

        -- Then add the materialization effect flags
        buildingAtPosition.justPlaced = true
        buildingAtPosition.placedTime = love.timer.getTime()
        buildingAtPosition.materializeProgress = 0.0

        -- Play Rock appearance sound if SFX is enabled
        if SETTINGS.AUDIO.SFX then
            soundCache.play("assets/audio/Maximize3.wav", {
                volume = SETTINGS.AUDIO.SFX_VOLUME
            })
        end
    end)

    -- Add to Rocks list
    if not self.neutralBuildings then
        self.neutralBuildings = {}
    end

    table.insert(self.neutralBuildings, {
        building = neutralBuilding,
        row = row,
        col = col
    })

    -- Add to turnlog
    if #self.neutralBuildings == 1 then
        self:addLogEntryString("Setup phase begins")
    end

    self:addLogEntry("0", "A Rock placed in " .. self:gridToChessNotation(row, col))

    -- If we've placed all required Rocks, move to next phase
    if #self.neutralBuildings >= self.totalNeutralBuildings then
        -- Move to next phase (Commandant placement)
        self:nextGamePhase()
        return true
    end

    return true
end

function gameRuler:initializeUnitActionTracking()
    if not self.currentGrid then return end

    for row = 1, self.currentGrid.rows do
        for col = 1, self.currentGrid.cols do
            local unit = self.currentGrid:getUnitAt(row, col)
            if unit and unit.player == self.currentPlayer then
                -- Track what actions this unit has performed this turn
                unit.turnActions = unit.turnActions or {}
                -- Don't reset hasActed here - keep existing logic
            end
        end
    end
end

function gameRuler:canUnitPerformAction(row, col, actionType)
    local unit = self.currentGrid:getUnitAt(row, col)
    if not unit or unit.player ~= self.currentPlayer then
        return false
    end

    -- If unit is already marked as acted, it can't do anything
    if unit.hasActed then
        return false
    end

    -- Initialize action tracking if needed
    if not unit.turnActions then
        unit.turnActions = {}
    end

    -- Check if unit has already performed this action type
    if unit.turnActions[actionType] then
        return false -- Can't repeat action types
    end

    return true
end

-- Check if a unit has any legal actions available (move, attack, or repair)
function gameRuler:unitHasLegalActions(row, col)
    local unit = self.currentGrid:getUnitAt(row, col)
    if not unit or unit.player ~= self.currentPlayer then
        return false
    end

    -- If unit is already marked as acted, it can't do anything
    if unit.hasActed then
        return false
    end

    -- Check if unit can move
    if self:canUnitPerformAction(row, col, "move") then
        local moveRange = unitsInfo:getUnitMoveRange(unit, "UNIT_LEGAL_ACTIONS_CHECK")
        for dr = -moveRange, moveRange do
            for dc = -moveRange, moveRange do
                local newRow, newCol = row + dr, col + dc
                if self.currentGrid:isValidPosition(newRow, newCol) and 
                   (dr ~= 0 or dc ~= 0) and -- Not the same position
                   math.abs(dr) + math.abs(dc) <= moveRange then -- Within move range
                    local targetCell = self.currentGrid:getCell(newRow, newCol)
                    if targetCell and not targetCell.unit then
                        return true -- Found at least one valid move
                    end
                end
            end
        end
    end

    -- Check if unit can attack
    if self:unitHasValidAttacks(row, col) then
        return true
    end

    -- Check if unit can repair (only for Healer)
    if unit.name == "Healer" and self:canUnitPerformAction(row, col, "repair") then
        -- Check orthogonally adjacent cells for friendly units or Commandant
        local directions = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}} -- Up, Down, Left, Right
        for _, dir in ipairs(directions) do
            local targetRow, targetCol = row + dir[1], col + dir[2]
            if self.currentGrid:isValidPosition(targetRow, targetCol) then
                local targetUnit = self.currentGrid:getUnitAt(targetRow, targetCol)
                if targetUnit and targetUnit.player == self.currentPlayer then
                    return true -- Found at least one orthogonally adjacent friendly unit that can be repaired
                end
            end
        end
    end

    return false -- No legal actions found
end

function gameRuler:recordUnitAction(row, col, actionType)
    local unit = self.currentGrid:getUnitAt(row, col)
    if not unit then return false end

    -- Initialize tracking if needed
    if not unit.turnActions then
        unit.turnActions = {}
    end

    -- Record this action type
    unit.turnActions[actionType] = true

    unit.actionsUsed = (unit.actionsUsed or 0) + 1

    -- Mark unit as acted if it was attack or repair
    if actionType == "attack" or actionType == "repair" then
        unit.hasActed = true
    end

    return true
end

-- Place Commandant for current player
function gameRuler:placeCommandHub(row, col)
    -- Validate position first
    local isValid, errorMsg = self:validateCommandHubPosition(row, col)
    if not isValid then
        return false, errorMsg
    end

    -- Get Commandant from player's supply
    local commandHub = nil
    local commandHubIndex = nil
    local playerSupply = self:getCurrentPlayerSupply(self.currentPlayer) or {}

    -- Find Commandant in player's supply
    for i, unit in ipairs(playerSupply) do
        if unit.name == "Commandant" then
            commandHub = unit
            commandHubIndex = i
            break
        end
    end

    if not commandHub then
        return false
    end

    -- Remove any existing temporary Commandant
    self:removeTemporaryCommandHub()

    -- Set player ownership and initialize HP
    commandHub.player = self.currentPlayer
    commandHub.currentHp = commandHub.startingHp

    commandHub.isHologram = true

    -- Place on grid (temporary placement)
    local success = self.currentGrid:placeUnit(commandHub, row, col)
    if not success then
        return false
    end

    -- Play Commandant hologram appearance sound if SFX is enabled
    if SETTINGS.AUDIO.SFX then
        soundCache.play("assets/audio/Maximize4.wav", {
            volume = SETTINGS.AUDIO.SFX_VOLUME
        })
    end

    -- Store temporary Commandant position and supply index
    if not self.tempCommandHubPosition then
        self.tempCommandHubPosition = {}
    end

    self.tempCommandHubPosition[self.currentPlayer] = {
        row = row,
        col = col,
        commandHubIndex = commandHubIndex
    }

    -- Show deployment cells around the Commandant
    self.currentGrid:forceShowDeploymentCells(row, col, self.currentPlayer)

    -- Enable the confirmation button in UI
    -- Auto-confirm for AI players
    if (GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and self.currentPlayer == GAME.CURRENT.AI_PLAYER_NUMBER) or
       (GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI) then
        self:confirmCommandHub()
    else
        self.commandHubPlacementReady = true
    end

    return true
end

function gameRuler:calcHowManyUnitsMustBeDeployed(hubRow, hubCol)
    -- Store current hub position
    self.initialDeployment.hubPosition = {row = hubRow, col = hubCol}

    -- Find free cells around the Commandant
    local freeCells = self:getFreeCellsAroundPosition(hubRow, hubCol)

    -- Store the available cells
    self.initialDeployment.availableCells = freeCells

    -- Set required deployments count to the number of free cells
    self.initialDeployment.requiredDeployments = INITIAL_DEPLOY_RULES.COUNT or 1
    self.initialDeployment.completedDeployments = 0

    -- Reset selected unit
    self.initialDeployment.selectedUnitIndex = nil

    return true
end

-- Confirm previously placed Commandant
function gameRuler:confirmCommandHub()
    if not self.tempCommandHubPosition or not self.tempCommandHubPosition[self.currentPlayer] then
        return false
    end

    local tempPos = self.tempCommandHubPosition[self.currentPlayer]
    local hubUnit = self.currentGrid:getUnitAt(tempPos.row, tempPos.col)
    local playerSupply = self:getCurrentPlayerSupply(self.currentPlayer) or {}

    -- Add these lines to apply the materialization effect
    if hubUnit then
        -- Remove hologram flag
        hubUnit.isHologram = nil

        -- Add materialization effect
        hubUnit.justPlaced = true
        hubUnit.placedTime = love.timer.getTime()
        
        -- Play Commandant confirmation sound if SFX is enabled
        if SETTINGS.AUDIO.SFX then
            soundCache.play("assets/audio/Maximize4.wav", {
                volume = SETTINGS.AUDIO.SFX_VOLUME
            })
        end
    end
    
    if not self.commandHubPositions then
        self.commandHubPositions = {}
    end

    self.commandHubPositions[self.currentPlayer] = {
        row = tempPos.row,
        col = tempPos.col
    }

    -- Remove Commandant from player's supply
    if tempPos.commandHubIndex then
        table.remove(playerSupply, tempPos.commandHubIndex)
    end

    -- Setup for initial deployment
    self:calcHowManyUnitsMustBeDeployed(self.commandHubPositions[self.currentPlayer].row, self.commandHubPositions[self.currentPlayer].col)
    tempPos = nil

    -- Reset the temporary placement
    self.tempCommandHubPosition[self.currentPlayer] = nil
    self.commandHubPlacementReady = false

    -- Clear any existing highlights
    if self.currentGrid then
        self.currentGrid:clearHighlightedCells()
        self.currentGrid:clearForcedHighlightedCells()
    end

    -- Instead of going to next game phase, go to unit deployment phase
    if self.currentPhase == PHASES.DEPLOY1 then
        self:setPhase(PHASES.DEPLOY1_UNITS)
    else
        self:setPhase(PHASES.DEPLOY2_UNITS)
    end

    -- Add to log
    self:addLogEntry(self.currentPlayer,
                    "Commandant in",
                    self.commandHubPositions[self.currentPlayer].row,
                    self.commandHubPositions[self.currentPlayer].col)

    return true
end

--------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------

-- Get free orthogonal cells around a position
function gameRuler:getFreeCellsAroundPosition(row, col)
    if not self.currentGrid then return {} end

    local freeCells = {}

    -- Check all four directions (up, down, left, right)
    local directions = {
        {row = row-1, col = col}, -- Up
        {row = row+1, col = col}, -- Down
        {row = row, col = col-1}, -- Left
        {row = row, col = col+1}  -- Right
    }

    for _, dir in ipairs(directions) do
        if self.currentGrid:isValidPosition(dir.row, dir.col) and 
           self.currentGrid:isCellEmpty(dir.row, dir.col) then
            table.insert(freeCells, {row = dir.row, col = dir.col})
        end
    end

    return freeCells
end

-- Check if a position is in the available cells list
function gameRuler:isPositionInAvailableCells(row, col, availableCells)
    for _, cell in ipairs(availableCells) do
        if cell.row == row and cell.col == col then
            return true
        end
    end
    return false
end

-- Get the number of deployments still required
function gameRuler:getRemainingRequiredDeployments()
    return math.max(0, self.initialDeployment.requiredDeployments - self.initialDeployment.completedDeployments)
end

-- Check if all required deployments have been completed
function gameRuler:isInitialDeploymentComplete()
    return self.initialDeployment.completedDeployments >= self.initialDeployment.requiredDeployments
end

-- Create a Rock with row-specific image variation
function gameRuler:createRandomNeutralBuilding(row)

    local building = unitsInfo:getUnitInfo("Rock")
    
    -- Check if building exists to prevent nil errors
    if not building then
        return nil
    end
    
    -- Create a copy to avoid modifying the original
    local buildingCopy = {}
    for k, v in pairs(building) do
        buildingCopy[k] = v
    end
    
    buildingCopy.player = 0

    -- Initialize health points
    if buildingCopy.startingHp then
        buildingCopy.currentHp = buildingCopy.startingHp
    end

    -- Assign different building image based on row (rows 3-6 use buildings 1-4)
    if row then
        local buildingVariant = ((row - 3) % 4) + 1  -- Maps row 3->1, 4->2, 5->3, 6->4, then cycles
        buildingCopy.path = "assets/sprites/NeutralBulding" .. buildingVariant .. "_Resized.png"
        buildingCopy.pathRed = buildingCopy.path  -- Rocks don't have red variants
    else
        -- Fallback to default if no row specified
        buildingCopy.path = "assets/sprites/NeutralBulding1_Resized.png"
        buildingCopy.pathRed = buildingCopy.path
    end

    return buildingCopy
end

function gameRuler:isAnimationInProgress()
    -- Check if grid has active animations
    if self.currentGrid then
        if self.currentGrid.movingUnits and #self.currentGrid.movingUnits > 0 then
            return true
        end

        -- Check for attack/beam effects
        if self.currentGrid.activeEffects and #self.currentGrid.activeEffects > 0 then
            return true
        end
    end

    -- Check scheduled actions
    if self.scheduledActions and #self.scheduledActions > 0 then
        return true
    end

    return false
end

-- Find a random free position on the grid
function gameRuler:findRandomFreePosition()
    if not self.currentGrid then return nil, nil end

    -- Get grid dimensions
    local maxRow = self.currentGrid.rows or GAME.CONSTANTS.GRID_SIZE
    local maxCol = self.currentGrid.cols or GAME.CONSTANTS.GRID_SIZE
    local minRow = 1
    local minCol = 1

    -- Keep track of tried positions
    local triedPositions = {}
    local maxAttempts = 20

    -- Try random positions first
    for attempt = 1, maxAttempts do
        local row = self:logicRandomInt(minRow, maxRow)
        local col = self:logicRandomInt(minCol, maxCol)
        local posKey = row .. "," .. col

        if not triedPositions[posKey] then
            triedPositions[posKey] = true
            if self.currentGrid:isValidPosition(row, col) and self.currentGrid:isCellEmpty(row, col) then
                return row, col
            end
        end
    end

    -- If random fails, try systematic search
    for row = minRow, maxRow do
        for col = minCol, maxCol do
            if self.currentGrid:isValidPosition(row, col) and self.currentGrid:isCellEmpty(row, col) then
                return row, col
            end
        end
    end

    -- No free position found
    return nil, nil
end

function gameRuler:selectSupplyUnit(unitIndex)
    -- Handle different phases
    if self.currentPhase == PHASES.DEPLOY1_UNITS or self.currentPhase == PHASES.DEPLOY2_UNITS then
        -- Initial deployment phase logic (existing)
        self.initialDeployment.selectedUnitIndex = unitIndex

        -- Get the Commandant position
        local hubPos = self.commandHubPositions[self.currentPlayer]

        if hubPos and self.currentGrid then
            -- Force show deployment cells
            self.currentGrid:forceShowDeploymentCells(hubPos.row, hubPos.col, self.currentPlayer)
        end
        
    elseif self.currentPhase == PHASES.TURN and self.currentTurnPhase == TURN_PHASES.ACTIONS then
        -- Actions phase deployment logic
        
        -- Re-implement the validation check
        if not self:canDeployInActionsPhase() then
            -- Return false with a specific error message based on the failure reason
            if self.hasDeployedThisTurn then
                return false, "Already deployed this turn"
            elseif self:areActionsComplete() then
                return false, "No actions remaining"
            elseif not self.commandHubPositions[self.currentPlayer] then
                return false, "No Commandant found"
            else
                -- Check if there are free cells around the Commandant
                local hubPos = self.commandHubPositions[self.currentPlayer]
                local freeCells = self:getFreeCellsAroundPosition(hubPos.row, hubPos.col)
                if not freeCells or #freeCells == 0 then
                    return false, "No free cells around Commandant"
                end
                
                -- Check if there are units in supply
                local supply = nil
                if self.currentPlayer == 1 then
                    supply = self.player1Supply
                else
                    supply = self.player2Supply
                end
                
                if not supply or #supply == 0 then
                    return false, "No units in supply"
                end
                
                return false, "Cannot deploy in actions phase"
            end
        end
        
        -- Store selected unit for actions phase
        self.actionsPhaseSupplySelection = unitIndex
        
        -- Get the Commandant position and show deployment cells
        local hubPos = self.commandHubPositions[self.currentPlayer]
        
        if hubPos and self.currentGrid then
            self.currentGrid:forceShowDeploymentCells(hubPos.row, hubPos.col, self.currentPlayer)
        end
    end

    return true
end

function gameRuler:deployUnitNearHub(row, col, unitIndex)
    local resolvedUnitIndex = tonumber(unitIndex)
    if resolvedUnitIndex then
        resolvedUnitIndex = math.floor(resolvedUnitIndex)
    else
        resolvedUnitIndex = self.initialDeployment.selectedUnitIndex
    end

    if not resolvedUnitIndex or resolvedUnitIndex < 1 then
        return false
    end

    -- Check if the position is valid for deployment
    local isValidPosition = false
    for _, cell in ipairs(self.initialDeployment.availableCells) do
        if cell.row == row and cell.col == col then
            isValidPosition = true
            break
        end
    end

    if not isValidPosition then
        return false
    end

    -- Get player supply and selected unit
    local playerSupply = self:getCurrentPlayerSupply(self.currentPlayer) or {}
    local unitIndex = resolvedUnitIndex
    local selectedUnit = playerSupply[unitIndex]

    if not selectedUnit then
        return false
    end

    -- Set player ownership and initialize HP if needed
    selectedUnit.player = self.currentPlayer
    if selectedUnit.startingHp then
        selectedUnit.currentHp = selectedUnit.startingHp
    end

    -- Create beam effect and pass the unit directly
    self.currentGrid:createBeamEffect(row, col, selectedUnit)
    
    -- Play teleport whoosh sound when unit evocation effect starts
    if self.currentGrid and self.currentGrid.playTeleportSound then
        self.currentGrid:playTeleportSound()
    end
    
    -- Remove from available cells
    for i, cell in ipairs(self.initialDeployment.availableCells) do
        if cell.row == row and cell.col == col then
            table.remove(self.initialDeployment.availableCells, i)
            break
        end
    end
    
    -- Remove from player supply immediately 
    table.remove(playerSupply, unitIndex)
    
    -- Add log entry now
    self:addLogEntry(self.currentPlayer,
                    "deploy " .. selectedUnit.name .. " in",
                    row,
                    col
    )
    
    self.gameStats.players[self.currentPlayer].unitsDeployed = self.gameStats.players[self.currentPlayer].unitsDeployed + 1
    
    -- Unit type stats
    if self.gameStats.unitStats[selectedUnit.name] then
        self.gameStats.unitStats[selectedUnit.name].deployed = self.gameStats.unitStats[selectedUnit.name].deployed + 1
    end
    
    -- Increment completed deployments
    self.initialDeployment.completedDeployments = self.initialDeployment.completedDeployments + 1
    
    -- Reset selected unit
    self.initialDeployment.selectedUnitIndex = nil

    -- Clear highlights
    self.currentGrid:clearHighlightedCells()
    self.currentGrid:clearForcedHighlightedCells()

    return true
end

-- Confirm completion of initial deployment
function gameRuler:currentPlayerStartingUnitsAllDeployed()
    -- Only allow confirmation if all required deployments are completed
    if not self:isInitialDeploymentComplete() then
        return false
    end

    -- Clear highlights
    if self.currentGrid then
        self.currentGrid:clearHighlightedCells()
        self.currentGrid:clearForcedHighlightedCells()
    end

    -- Recalculate action count before moving to next phase
    self:recalculateMaxActions()

    if self.currentTurn == 0 and self.currentPlayer == 2 then
        self:addLogEntryString("Setup phase completed")
        self.currentTurn = 1
        self:addLogEntryString("Turn 1 begins")
    end

    -- Move to next game phase
    self:nextGamePhase()

    return true
end

-- Return to main menu from game over state
function gameRuler:returnToMainMenu()
    -- Call the global state machine to change state
    if GAME.STATE_MACHINE then
        GAME.STATE_MACHINE:changeState("mainMenu")
    end
end

--------------------------------------------------
return gameRuler
