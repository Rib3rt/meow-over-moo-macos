local scenarioSelect = {}

-- SCENARIO-ONLY SCREEN:
-- Keep this module isolated from standard game modes.
-- Any behavior added here must affect scenario mode only.

local ConfirmDialog = require("confirmDialog")
local uiTheme = require("uiTheme")
local soundCache = require("soundCache")
local os = require("os")

local stateMachineRef = nil
local uiButtons = nil
local buttonOrder = {}
local selectedButtonIndex = 1
local listFocus = true

local scenarioRows = {}
local selectedRowIndex = 1
local scrollOffsetRows = 0
local progressData = nil
local runtimeProgressData = nil
local scenarioLoadedDefinitionsById = {}

local statusText = "Select a scenario."
local statusSeverity = "info"

local scrollbarDragging = false
local scrollbarDragAnchorY = 0
local scrollbarDragAnchorOffset = 0
local lastHoveredTarget = nil

local BUTTON_BEEP_SOUND_PATH = "assets/audio/GenericButton14.wav"
local BUTTON_CLICK_SOUND_PATH = "assets/audio/GenericButton6.wav"
local SCENARIO_PROGRESS_FILE = "ScenarioProgress.dat"
local SCENARIO_PROGRESS_VERSION = 1
local SCENARIO_SCRIPTS_DIR = "scenarios"

runtimeProgressData = {
    version = SCENARIO_PROGRESS_VERSION,
    scenarios = {}
}

local LAYOUT = {
    panelMarginX = 40,
    topPanelY = 40,
    topPanelHeight = 76,
    listTop = 130,
    panelBottom = 130,
    listHeaderHeight = 34,
    listPadding = 10,
    listColumnsHeaderHeight = 24,
    rowHeight = 36,
    scrollbarWidth = 12,
    buttonRowY = SETTINGS.DISPLAY.HEIGHT - 100,
    buttonWidth = 210,
    buttonHeight = 50
}

local SCENARIO_DEFINITIONS = {
    {
        id = "P001",
        name = "Scenario P001",
        status = "READY",
        file = "scenarios/P001.lua"
    }
}

local function cloneSequence(source)
    local out = {}
    for index, value in ipairs(source or {}) do
        out[index] = value
    end
    return out
end

local function cloneMap(source)
    local out = {}
    for key, value in pairs(source or {}) do
        out[key] = value
    end
    return out
end

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

local function normalizeScenarioId(rawId, fallback)
    local value = tostring(rawId or fallback or "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value
end

local function scenarioFileStem(path)
    local stem = tostring(path or "")
    stem = stem:gsub("\\", "/")
    stem = stem:match("([^/]+)$") or stem
    stem = stem:gsub("%.lua$", "")
    return stem
end

local function listScenarioScriptFiles()
    if not (love and love.filesystem and type(love.filesystem.getDirectoryItems) == "function" and type(love.filesystem.getInfo) == "function") then
        return {}
    end

    local ok, items = pcall(love.filesystem.getDirectoryItems, SCENARIO_SCRIPTS_DIR)
    if not ok or type(items) ~= "table" then
        return {}
    end

    table.sort(items, function(a, b)
        return tostring(a) < tostring(b)
    end)

    local discovered = {}
    for _, item in ipairs(items) do
        local itemName = tostring(item or "")
        if itemName:match("%.lua$") then
            local path = SCENARIO_SCRIPTS_DIR .. "/" .. itemName
            local infoOk, info = pcall(love.filesystem.getInfo, path)
            if infoOk and type(info) == "table" and info.type == "file" then
                discovered[#discovered + 1] = path
            end
        end
    end
    return discovered
end

local function loadScenarioScriptTable(path)
    if type(path) ~= "string" or path == "" then
        return nil, "missing_path"
    end

    local chunk, loadErr
    if love and love.filesystem and type(love.filesystem.load) == "function" then
        local ok, loaded = pcall(love.filesystem.load, path)
        if not ok or type(loaded) ~= "function" then
            return nil, "load_failed:" .. tostring(loaded or loadErr)
        end
        chunk = loaded
    else
        chunk, loadErr = loadfile(path)
        if type(chunk) ~= "function" then
            return nil, "load_failed:" .. tostring(loadErr or "unknown")
        end
    end

    local ok, payload = pcall(chunk)
    if not ok then
        return nil, "runtime_failed:" .. tostring(payload)
    end
    if type(payload) ~= "table" then
        return nil, "invalid_payload"
    end
    return payload, nil
end

local function normalizeScenarioScriptPayload(payload, path)
    if type(payload) ~= "table" then
        return nil, "invalid_payload"
    end

    local fallbackId = scenarioFileStem(path)
    local scenarioId = normalizeScenarioId(payload.id, fallbackId)
    if scenarioId == "" then
        return nil, "missing_id"
    end

    local snapshot = payload.startSnapshot or payload.snapshot
    if type(snapshot) ~= "table" then
        return nil, "missing_start_snapshot"
    end

    local turnsTarget = tonumber(payload.turnLimitRounds or payload.turnsTarget or payload.turnLimit)
    if turnsTarget and turnsTarget > 0 then
        turnsTarget = math.floor(turnsTarget)
    else
        turnsTarget = nil
    end

    local name = payload.name or payload.title or scenarioId
    local status = payload.status or "READY"
    local objectiveMessage = payload.objectiveMessage or payload.objectiveText
    local objectiveType = payload.objectiveType
    local sideToMove = payload.sideToMove

    return {
        id = scenarioId,
        name = tostring(name),
        status = tostring(status),
        turnsTarget = turnsTarget,
        objectiveMessage = objectiveMessage and tostring(objectiveMessage) or nil,
        objectiveText = payload.objectiveText and tostring(payload.objectiveText) or nil,
        objectiveType = objectiveType and tostring(objectiveType) or nil,
        sideToMove = sideToMove and tostring(sideToMove) or nil,
        snapshot = cloneValue(snapshot),
        sourcePath = path
    }, nil
end

local function getScenarioDefinitionById(scenarioId)
    for _, definition in ipairs(SCENARIO_DEFINITIONS) do
        if tostring(definition.id or "") == tostring(scenarioId or "") then
            return definition
        end
    end
    return nil
end

local function computeScenarioIntegritySignature(boardUnits)
    local signature = {
        boardUnitTotal = 0,
        boardByPlayer = { [0] = 0, [1] = 0, [2] = 0 },
        supplyByPlayer = { [1] = 0, [2] = 0 },
        commandants = { [1] = 0, [2] = 0 }
    }

    for _, entry in ipairs(boardUnits or {}) do
        local player = tonumber(entry.player)
        if player ~= 1 and player ~= 2 then
            player = 0
        end

        signature.boardUnitTotal = signature.boardUnitTotal + 1
        signature.boardByPlayer[player] = (signature.boardByPlayer[player] or 0) + 1
        if tostring(entry.name or "") == "Commandant" and (player == 1 or player == 2) then
            signature.commandants[player] = (signature.commandants[player] or 0) + 1
        end
    end

    return signature
end

local function buildScenarioSnapshotFromBoard(definition)
    if not definition or type(definition.board) ~= "table" then
        return nil, "missing_definition"
    end

    local commandHubPositions = {}
    local boardUnits = {}
    for _, entry in ipairs(definition.board) do
        local row = tonumber(entry.row)
        local col = tonumber(entry.col)
        local player = tonumber(entry.player)
        local unitName = tostring(entry.name or "")
        if row and col and (player == 1 or player == 2) and unitName ~= "" then
            boardUnits[#boardUnits + 1] = {
                row = row,
                col = col,
                name = unitName,
                player = player,
                hasActed = false,
                turnActions = {}
            }
            if unitName == "Commandant" then
                commandHubPositions[player] = { row = row, col = col }
            end
        end
    end

    if not commandHubPositions[2] then
        return nil, "missing_red_commandant"
    end
    if commandHubPositions[1] then
        return nil, "blue_commandant_not_allowed"
    end

    local turnOrder = cloneSequence((GAME and GAME.CURRENT and GAME.CURRENT.TURN_ORDER) or {1, 2})
    if #turnOrder == 0 then
        turnOrder = {1, 2}
    end
    local factionAssignments = cloneMap((GAME and GAME.CURRENT and GAME.CURRENT.FACTION_ASSIGNMENTS) or { [1] = nil, [2] = nil })

    local integritySignature = computeScenarioIntegritySignature(boardUnits)

    return {
        version = 4,
        currentPhase = "turn",
        currentTurnPhase = "actions",
        currentTurn = 1,
        currentPlayer = 1,
        turnOrder = turnOrder,
        factionAssignments = factionAssignments,
        winner = nil,
        maxActionsPerTurn = 2,
        currentTurnActions = 0,
        hasDeployedThisTurn = true,
        commandHubPositions = commandHubPositions,
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
        logicRngSeed = 12001 + #boardUnits,
        logicRngState = 12001 + #boardUnits,
        neutralBuildings = {},
        neutralBuildingsPlaced = 0,
        targetRows = {3, 4, 5, 6},
        usedRows = {},
        actionsPhaseSupplySelection = nil,
        playerSupplies = {
            [1] = {},
            [2] = {}
        },
        boardUnits = boardUnits,
        integritySignature = integritySignature,
        gridSetupComplete = {
            [1] = true,
            [2] = true
        }
    }, nil
end

local function buildScenarioSnapshot(scenarioId)
    local key = tostring(scenarioId or "")
    local loaded = scenarioLoadedDefinitionsById[key]
    if loaded and type(loaded.snapshot) == "table" then
        return cloneValue(loaded.snapshot), nil
    end

    local definition = getScenarioDefinitionById(scenarioId)
    if not definition then
        return nil, "missing_definition"
    end
    if type(definition.board) == "table" then
        return buildScenarioSnapshotFromBoard(definition)
    end
    if type(definition.startSnapshot) == "table" or type(definition.snapshot) == "table" then
        local rawSnapshot = definition.startSnapshot or definition.snapshot
        return cloneValue(rawSnapshot), nil
    end
    return nil, "missing_snapshot"
end

local function initAudio()
    soundCache.get(BUTTON_BEEP_SOUND_PATH)
    soundCache.get(BUTTON_CLICK_SOUND_PATH)
end

local function playHoverSound()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(BUTTON_BEEP_SOUND_PATH, {
        clone = false,
        volume = SETTINGS.AUDIO.SFX_VOLUME,
        category = "sfx"
    })
end

local function playClickSound()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(BUTTON_CLICK_SOUND_PATH, {
        clone = false,
        volume = SETTINGS.AUDIO.SFX_VOLUME,
        category = "sfx"
    })
end

local function setStatusBar(textValue, severity)
    statusText = tostring(textValue or "")
    statusSeverity = severity or "info"
end

local function getStatusBarColor()
    if statusSeverity == "error" then
        return 0.78, 0.34, 0.34, 0.95
    end
    if statusSeverity == "warn" then
        return 0.84, 0.72, 0.36, 0.95
    end
    if statusSeverity == "ok" then
        return 0.45, 0.75, 0.55, 0.95
    end
    return 0.72, 0.74, 0.78, 0.95
end

local function usingLoveFilesystem()
    return love
        and love.filesystem
        and type(love.filesystem.write) == "function"
        and type(love.filesystem.read) == "function"
end

local function resolveStoragePath()
    if usingLoveFilesystem() and type(love.filesystem.getSaveDirectory) == "function" then
        local ok, saveDir = pcall(love.filesystem.getSaveDirectory)
        if ok and type(saveDir) == "string" and saveDir ~= "" then
            local normalized = saveDir:gsub("[/\\]+$", "")
            return normalized .. "/" .. SCENARIO_PROGRESS_FILE
        end
    end
    return SCENARIO_PROGRESS_FILE
end

local function readRawProgress()
    if usingLoveFilesystem() then
        local ok, content = pcall(love.filesystem.read, SCENARIO_PROGRESS_FILE)
        if ok and type(content) == "string" then
            return content
        end
        return nil
    end

    local file = io.open(resolveStoragePath(), "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function writeRawProgress(content)
    if usingLoveFilesystem() then
        local ok, result = pcall(love.filesystem.write, SCENARIO_PROGRESS_FILE, content)
        if ok then
            return result == true
        end
        return false
    end

    local path = resolveStoragePath()
    local tmpPath = path .. ".tmp"
    local file = io.open(tmpPath, "w")
    if not file then
        return false
    end
    file:write(content)
    file:close()

    local renamed = os.rename(tmpPath, path)
    if not renamed then
        os.remove(path)
        renamed = os.rename(tmpPath, path)
    end
    if not renamed then
        os.remove(tmpPath)
        return false
    end
    return true
end

local function sortKeys(keys)
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == tb then
            if ta == "number" then
                return a < b
            end
            return tostring(a) < tostring(b)
        end
        return ta < tb
    end)
end

local function isIdentifier(str)
    return type(str) == "string" and str:match("^[%a_][%w_]*$") ~= nil
end

local function serializeValue(value, seen)
    local valueType = type(value)
    if valueType == "nil" then
        return "nil"
    end
    if valueType == "boolean" then
        return value and "true" or "false"
    end
    if valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "0"
        end
        return tostring(value)
    end
    if valueType == "string" then
        return string.format("%q", value)
    end
    if valueType ~= "table" then
        return "nil"
    end

    if seen[value] then
        return "nil"
    end
    seen[value] = true

    local isArray = true
    local maxIndex = 0
    for key, _ in pairs(value) do
        if type(key) == "number" and key >= 1 and math.floor(key) == key then
            if key > maxIndex then
                maxIndex = key
            end
        else
            isArray = false
            break
        end
    end

    if isArray then
        for i = 1, maxIndex do
            if value[i] == nil then
                isArray = false
                break
            end
        end
    end

    local parts = {}
    if isArray then
        for i = 1, maxIndex do
            parts[#parts + 1] = serializeValue(value[i], seen)
        end
    else
        local keys = {}
        for key, _ in pairs(value) do
            keys[#keys + 1] = key
        end
        sortKeys(keys)
        for _, key in ipairs(keys) do
            local keyExpr = isIdentifier(key) and key or ("[" .. serializeValue(key, seen) .. "]")
            parts[#parts + 1] = keyExpr .. "=" .. serializeValue(value[key], seen)
        end
    end

    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function encodeProgress(data)
    return "return " .. serializeValue(data, {}) .. "\n"
end

local function decodeProgress(content)
    if type(content) ~= "string" or content == "" then
        return nil
    end

    local loader = loadstring or load
    local chunk
    if loader == load then
        chunk = loader(content, "@" .. SCENARIO_PROGRESS_FILE, "t", {})
    else
        chunk = loader(content, "@" .. SCENARIO_PROGRESS_FILE)
    end
    if not chunk then
        return nil
    end

    local ok, value = pcall(chunk)
    if not ok or type(value) ~= "table" then
        return nil
    end
    return value
end

local function loadProgressData()
    runtimeProgressData = runtimeProgressData or {
        version = SCENARIO_PROGRESS_VERSION,
        scenarios = {}
    }
    runtimeProgressData.version = SCENARIO_PROGRESS_VERSION
    if type(runtimeProgressData.scenarios) ~= "table" then
        runtimeProgressData.scenarios = {}
    end
    return runtimeProgressData
end

local function saveProgressData(data)
    if type(data) ~= "table" then
        return false
    end
    data.version = SCENARIO_PROGRESS_VERSION
    data.scenarios = type(data.scenarios) == "table" and data.scenarios or {}
    runtimeProgressData = data
    return true
end

local function getScenarioProgressEntry(scenarioId)
    progressData = progressData or loadProgressData()
    progressData.scenarios = progressData.scenarios or {}
    local key = tostring(scenarioId or "")
    local entry = progressData.scenarios[key]
    if type(entry) ~= "table" then
        entry = { attempts = 0, solved = false }
        progressData.scenarios[key] = entry
    end

    entry.attempts = math.max(0, tonumber(entry.attempts) or 0)
    entry.solved = entry.solved == true
    return entry
end

local function buildScenarioRows()
    scenarioRows = {}
    scenarioLoadedDefinitionsById = {}

    local seenIds = {}
    local seenPaths = {}

    local function registerLoadedScenario(rowData)
        if type(rowData) ~= "table" then
            return
        end
        local scenarioId = normalizeScenarioId(rowData.id, nil)
        if scenarioId == "" or seenIds[scenarioId] then
            return
        end

        local progressEntry = getScenarioProgressEntry(scenarioId)
        scenarioRows[#scenarioRows + 1] = {
            id = scenarioId,
            name = tostring(rowData.name or "Unnamed Scenario"),
            status = tostring(rowData.status or "READY"),
            turnsTarget = math.max(0, tonumber(rowData.turnsTarget) or 0),
            attempts = progressEntry.attempts,
            solved = progressEntry.solved,
            objectiveMessage = rowData.objectiveMessage,
            objectiveText = rowData.objectiveText,
            objectiveType = rowData.objectiveType,
            sideToMove = rowData.sideToMove,
            sourcePath = rowData.sourcePath
        }

        scenarioLoadedDefinitionsById[scenarioId] = {
            id = scenarioId,
            snapshot = type(rowData.snapshot) == "table" and cloneValue(rowData.snapshot) or nil,
            sourcePath = rowData.sourcePath
        }
        seenIds[scenarioId] = true
    end

    for _, definition in ipairs(SCENARIO_DEFINITIONS) do
        if type(definition) == "table" and type(definition.file) == "string" and definition.file ~= "" then
            seenPaths[definition.file] = true
            local payload, loadErr = loadScenarioScriptTable(definition.file)
            if payload then
                local normalized, normalizeErr = normalizeScenarioScriptPayload(payload, definition.file)
                if normalized then
                    if definition.name and tostring(definition.name) ~= "" then
                        normalized.name = tostring(definition.name)
                    end
                    if definition.status and tostring(definition.status) ~= "" then
                        normalized.status = tostring(definition.status)
                    end
                    registerLoadedScenario(normalized)
                else
                    print(string.format("[ScenarioSelect] invalid scenario file '%s': %s", tostring(definition.file), tostring(normalizeErr)))
                end
            else
                print(string.format("[ScenarioSelect] failed to load scenario file '%s': %s", tostring(definition.file), tostring(loadErr)))
            end
        elseif type(definition) == "table" then
            local scenarioId = normalizeScenarioId(definition.id, "")
            if scenarioId ~= "" and not seenIds[scenarioId] then
                local snapshot = nil
                local snapshotErr = nil
                if type(definition.startSnapshot) == "table" or type(definition.snapshot) == "table" then
                    snapshot = cloneValue(definition.startSnapshot or definition.snapshot)
                else
                    snapshot, snapshotErr = buildScenarioSnapshotFromBoard(definition)
                end
                if snapshot then
                    registerLoadedScenario({
                        id = scenarioId,
                        name = definition.name or scenarioId,
                        status = definition.status or "READY",
                        turnsTarget = definition.turnsTarget,
                        objectiveMessage = definition.objectiveMessage,
                        objectiveText = definition.objectiveText,
                        objectiveType = definition.objectiveType,
                        sideToMove = definition.sideToMove,
                        snapshot = snapshot,
                        sourcePath = definition.file
                    })
                else
                    print(string.format("[ScenarioSelect] failed to build inline scenario '%s': %s", tostring(scenarioId), tostring(snapshotErr)))
                end
            end
        end
    end

    for _, discoveredPath in ipairs(listScenarioScriptFiles()) do
        if not seenPaths[discoveredPath] then
            local payload, loadErr = loadScenarioScriptTable(discoveredPath)
            if payload then
                local normalized, normalizeErr = normalizeScenarioScriptPayload(payload, discoveredPath)
                if normalized then
                    registerLoadedScenario(normalized)
                else
                    print(string.format("[ScenarioSelect] invalid discovered scenario '%s': %s", tostring(discoveredPath), tostring(normalizeErr)))
                end
            else
                print(string.format("[ScenarioSelect] failed to load discovered scenario '%s': %s", tostring(discoveredPath), tostring(loadErr)))
            end
        end
    end
end

local function consumePendingScenarioResult()
    if not GAME or not GAME.CURRENT then
        return nil
    end
    local result = GAME.CURRENT.SCENARIO_RESULT
    GAME.CURRENT.SCENARIO_RESULT = nil
    if type(result) ~= "table" then
        return nil
    end
    return result
end

local function applyPendingScenarioResult(result)
    if type(result) ~= "table" then
        return nil
    end

    local scenarioId = tostring(result.id or "")
    if scenarioId == "" then
        return nil
    end

    local entry = getScenarioProgressEntry(scenarioId)
    local solved = result.solved == true
    if solved then
        entry.solved = true
    end

    local attempts = tonumber(result.attempts)
    if attempts then
        entry.attempts = math.max(entry.attempts or 0, math.max(0, math.floor(attempts)))
    end

    saveProgressData(progressData)
    return solved
end

local function listRect()
    local x = LAYOUT.panelMarginX
    local y = LAYOUT.listTop
    local width = SETTINGS.DISPLAY.WIDTH - (LAYOUT.panelMarginX * 2)
    local height = SETTINGS.DISPLAY.HEIGHT - LAYOUT.listTop - LAYOUT.panelBottom
    return x, y, width, height
end

local function listContentRect()
    local x, y, width, height = listRect()
    local contentX = x + LAYOUT.listPadding
    local contentY = y + LAYOUT.listHeaderHeight + LAYOUT.listPadding
    local contentWidth = width - (LAYOUT.listPadding * 2) - LAYOUT.scrollbarWidth - 4
    local contentHeight = height - LAYOUT.listHeaderHeight - (LAYOUT.listPadding * 2)
    return contentX, contentY, contentWidth, contentHeight
end

local function visibleRows()
    local _, _, _, contentHeight = listContentRect()
    local rowsHeight = math.max(0, contentHeight - LAYOUT.listColumnsHeaderHeight)
    return math.max(1, math.floor(rowsHeight / LAYOUT.rowHeight))
end

local function maxScrollOffsetRows()
    return math.max(0, #scenarioRows - visibleRows())
end

local function clampSelection()
    if #scenarioRows == 0 then
        selectedRowIndex = 1
        scrollOffsetRows = 0
        return
    end

    if selectedRowIndex < 1 then
        selectedRowIndex = 1
    elseif selectedRowIndex > #scenarioRows then
        selectedRowIndex = #scenarioRows
    end

    local visible = visibleRows()
    if selectedRowIndex <= scrollOffsetRows then
        scrollOffsetRows = selectedRowIndex - 1
    elseif selectedRowIndex > scrollOffsetRows + visible then
        scrollOffsetRows = selectedRowIndex - visible
    end

    local maxOffset = maxScrollOffsetRows()
    if scrollOffsetRows < 0 then
        scrollOffsetRows = 0
    elseif scrollOffsetRows > maxOffset then
        scrollOffsetRows = maxOffset
    end
end

local function setSelectedRowIndex(index)
    selectedRowIndex = index
    clampSelection()
end

local function setScrollOffsetRows(offset)
    local maxOffset = maxScrollOffsetRows()
    local nextOffset = math.floor(offset)
    if nextOffset < 0 then
        nextOffset = 0
    elseif nextOffset > maxOffset then
        nextOffset = maxOffset
    end
    scrollOffsetRows = nextOffset
    clampSelection()
end

local function scrollRows(delta)
    setScrollOffsetRows(scrollOffsetRows + delta)
end

local function scrollbarGeometry()
    local x, y, width, height = listRect()
    local trackX = x + width - LAYOUT.listPadding - LAYOUT.scrollbarWidth
    local trackY = y + LAYOUT.listHeaderHeight + LAYOUT.listPadding + LAYOUT.listColumnsHeaderHeight
    local trackHeight = height - LAYOUT.listHeaderHeight - (LAYOUT.listPadding * 2) - LAYOUT.listColumnsHeaderHeight

    local visible = visibleRows()
    local total = #scenarioRows
    if total <= visible then
        return {
            visible = false,
            trackX = trackX,
            trackY = trackY,
            trackHeight = trackHeight,
            thumbY = trackY,
            thumbHeight = trackHeight
        }
    end

    local maxOffset = maxScrollOffsetRows()
    local thumbHeight = math.max(24, math.floor(trackHeight * (visible / total)))
    local thumbTravel = trackHeight - thumbHeight
    local ratio = maxOffset > 0 and (scrollOffsetRows / maxOffset) or 0
    local thumbY = trackY + math.floor(thumbTravel * ratio)

    return {
        visible = true,
        trackX = trackX,
        trackY = trackY,
        trackHeight = trackHeight,
        thumbY = thumbY,
        thumbHeight = thumbHeight,
        thumbTravel = thumbTravel,
        maxOffset = maxOffset
    }
end

local function rowIndexAt(x, y)
    local contentX, contentY, contentWidth, contentHeight = listContentRect()
    local rowsTopY = contentY + LAYOUT.listColumnsHeaderHeight
    local rowsBottomY = contentY + contentHeight

    if x < contentX or x > contentX + contentWidth then
        return nil
    end
    if y < rowsTopY or y > rowsBottomY then
        return nil
    end

    local row = math.floor((y - rowsTopY) / LAYOUT.rowHeight) + 1
    local index = scrollOffsetRows + row
    if index < 1 or index > #scenarioRows then
        return nil
    end
    return index
end

local function isMouseOverButton(button, x, y)
    return button and x >= button.x and x <= button.x + button.width and y >= button.y and y <= button.y + button.height
end

local function selectEnabledButton(startIndex, delta)
    if #buttonOrder == 0 then
        return nil
    end

    local index = startIndex
    for _ = 1, #buttonOrder do
        if index < 1 then
            index = #buttonOrder
        elseif index > #buttonOrder then
            index = 1
        end
        if buttonOrder[index] and buttonOrder[index].enabled then
            return index
        end
        index = index + delta
    end

    return nil
end

local function ensureValidButtonSelection()
    local resolved = selectEnabledButton(selectedButtonIndex, 1) or selectEnabledButton(1, 1)
    if resolved then
        selectedButtonIndex = resolved
    end
end

local function updateButtonVisuals()
    for i, button in ipairs(buttonOrder) do
        local variant = button.enabled and "default" or "disabled"
        uiTheme.applyButtonVariant(button, variant)
        button.disabledVisual = not button.enabled
        button.focused = (i == selectedButtonIndex and not listFocus and button.enabled)
        button.currentColor = button.focused and button.hoverColor or button.baseColor
    end
end

local function updateButtonStates()
    uiButtons.back.enabled = true
    if #scenarioRows == 0 then
        listFocus = false
    end
    if not listFocus or #scenarioRows == 0 then
        ensureValidButtonSelection()
    end
    updateButtonVisuals()
end

local function clearOnlineRuntime()
    GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
    local online = GAME.CURRENT.ONLINE
    online.active = false
    online.role = nil
    online.factionRole = nil
    online.session = nil
    online.lockstep = nil
    online.autoJoinLobbyId = nil
    online.pendingLobbyEvents = {}
end

local function activateScenario(index)
    local row = scenarioRows[index]
    if not row then
        return
    end
    setSelectedRowIndex(index)
    listFocus = true
    setStatusBar(
        string.format("%s selected. Scenario runtime is disabled (UI-only mode). Open EDITOR to continue.", row.name),
        "warn"
    )
end

local function onBack()
    if stateMachineRef then
        stateMachineRef.changeState("mainMenu")
    end
end

local function onEditor()
    if stateMachineRef then
        stateMachineRef.changeState("scenarioEditor")
    end
end

local function triggerSelectedButton(button)
    if not button or not button.enabled then
        return
    end

    playClickSound()

    if button == uiButtons.back then
        onBack()
    elseif button == uiButtons.editor then
        onEditor()
    end

    updateButtonStates()
end

local function initializeButtons()
    local gap = 24
    local totalWidth = (LAYOUT.buttonWidth * 2) + gap
    local startX = math.floor((SETTINGS.DISPLAY.WIDTH - totalWidth) / 2)
    uiButtons = {
        back = {
            x = startX,
            y = LAYOUT.buttonRowY,
            width = LAYOUT.buttonWidth,
            height = LAYOUT.buttonHeight,
            text = "Back",
            enabled = true,
            currentColor = uiTheme.COLORS.button,
            hoverColor = uiTheme.COLORS.buttonHover,
            pressedColor = uiTheme.COLORS.buttonPressed
        },
        editor = {
            x = startX + LAYOUT.buttonWidth + gap,
            y = LAYOUT.buttonRowY,
            width = LAYOUT.buttonWidth,
            height = LAYOUT.buttonHeight,
            text = "EDITOR",
            enabled = true,
            currentColor = uiTheme.COLORS.button,
            hoverColor = uiTheme.COLORS.buttonHover,
            pressedColor = uiTheme.COLORS.buttonPressed
        }
    }

    buttonOrder = {uiButtons.back, uiButtons.editor}
    for _, button in ipairs(buttonOrder) do
        uiTheme.applyButtonVariant(button, "default")
    end
end

function scenarioSelect.enter(stateMachine)
    stateMachineRef = stateMachine

    initializeButtons()
    selectedButtonIndex = 1
    listFocus = true
    selectedRowIndex = 1
    scrollOffsetRows = 0
    scrollbarDragging = false
    lastHoveredTarget = nil

    progressData = loadProgressData()
    consumePendingScenarioResult()
    buildScenarioRows()
    clampSelection()

    if #scenarioRows == 0 then
        listFocus = false
        setStatusBar("No scenarios available.", "warn")
    else
        setStatusBar("UI-only mode: select a scenario or open EDITOR.", "info")
    end

    updateButtonStates()
end

function scenarioSelect.exit()
    stateMachineRef = nil
    scrollbarDragging = false
end

function scenarioSelect.update(dt)
    if ConfirmDialog.isActive() then
        ConfirmDialog.update(dt)
        return
    end

    clampSelection()
    updateButtonStates()
end

function scenarioSelect.draw()
    love.graphics.push()
    love.graphics.translate(SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY)
    love.graphics.scale(SETTINGS.DISPLAY.SCALE)

    love.graphics.setColor(uiTheme.COLORS.background)
    love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)

    local topPanelX = LAYOUT.panelMarginX
    local topPanelY = LAYOUT.topPanelY
    local topPanelW = SETTINGS.DISPLAY.WIDTH - (LAYOUT.panelMarginX * 2)
    local solvedCount = 0
    for _, row in ipairs(scenarioRows) do
        if row.solved then
            solvedCount = solvedCount + 1
        end
    end
    uiTheme.drawTechPanel(topPanelX, topPanelY, topPanelW, LAYOUT.topPanelHeight)

    love.graphics.setColor(0.90, 0.88, 0.82, 1)
    love.graphics.printf("AVAILABLE SCENARIOS", topPanelX + 12, topPanelY + 10, topPanelW - 24, "left")
    love.graphics.setColor(0.78, 0.82, 0.86, 1)
    love.graphics.printf(string.format("Solved senario %d/%d", solvedCount, #scenarioRows), topPanelX + 12, topPanelY + 42, topPanelW - 24, "left")

    local panelX, panelY, panelW, panelH = listRect()
    uiTheme.drawTechPanel(panelX, panelY, panelW, panelH)

    love.graphics.setColor(0.90, 0.88, 0.82, 1)
    love.graphics.printf("Scenario List", panelX + 12, panelY + 8, panelW - 24, "left")

    local contentX, contentY, contentW, contentH = listContentRect()
    local rowsTopY = contentY + LAYOUT.listColumnsHeaderHeight

    local colName = math.floor(contentW * 0.34)
    local colStatus = math.floor(contentW * 0.14)
    local colSolved = math.floor(contentW * 0.16)
    local colAttempts = math.floor(contentW * 0.20)
    local colTurns = contentW - (colName + colStatus + colSolved + colAttempts)

    love.graphics.setColor(0.15, 0.16, 0.18, 0.5)
    love.graphics.rectangle("fill", contentX, contentY, contentW, contentH)

    love.graphics.setColor(0.18, 0.20, 0.22, 0.9)
    love.graphics.rectangle("fill", contentX, contentY, contentW, LAYOUT.listColumnsHeaderHeight)
    love.graphics.setColor(0.76, 0.78, 0.82, 1)
    love.graphics.printf("Name", contentX + 8, contentY + 4, colName - 10, "left")
    love.graphics.printf("Status", contentX + colName + 6, contentY + 4, colStatus - 10, "left")
    love.graphics.printf("Solved", contentX + colName + colStatus + 6, contentY + 4, colSolved - 10, "left")
    love.graphics.printf("Attempts", contentX + colName + colStatus + colSolved + 6, contentY + 4, colAttempts - 10, "left")
    love.graphics.printf("Turns", contentX + colName + colStatus + colSolved + colAttempts + 6, contentY + 4, colTurns - 10, "left")

    if #scenarioRows == 0 then
        love.graphics.setColor(0.72, 0.70, 0.66, 1)
        love.graphics.printf("No scenarios available.", contentX + 8, rowsTopY + 10, contentW - 16, "left")
    else
        local visible = visibleRows()
        local startIndex = scrollOffsetRows + 1
        local endIndex = math.min(#scenarioRows, scrollOffsetRows + visible)
        for i = startIndex, endIndex do
            local row = scenarioRows[i]
            local rowY = rowsTopY + (i - startIndex) * LAYOUT.rowHeight
            local isSelected = i == selectedRowIndex

            if isSelected then
                if listFocus then
                    love.graphics.setColor(0.30, 0.44, 0.54, 0.9)
                else
                    love.graphics.setColor(0.24, 0.32, 0.38, 0.75)
                end
                love.graphics.rectangle("fill", contentX + 2, rowY + 1, contentW - 4, LAYOUT.rowHeight - 2)
            elseif ((i - startIndex) % 2) == 1 then
                love.graphics.setColor(1, 1, 1, 0.03)
                love.graphics.rectangle("fill", contentX + 2, rowY + 1, contentW - 4, LAYOUT.rowHeight - 2)
            end

            local solvedText = row.solved and "Solved" or "Unsolved"
            local attemptsText = tostring(row.attempts or 0)
            local turnsText = tostring(row.turnsTarget or 0)

            love.graphics.setColor(0.94, 0.92, 0.86, 1)
            love.graphics.printf(row.name, contentX + 8, rowY + 9, colName - 10, "left")
            love.graphics.printf(row.status, contentX + colName + 6, rowY + 9, colStatus - 10, "left")
            love.graphics.printf(solvedText, contentX + colName + colStatus + 6, rowY + 9, colSolved - 10, "left")
            love.graphics.printf(attemptsText, contentX + colName + colStatus + colSolved + 6, rowY + 9, colAttempts - 10, "left")
            love.graphics.printf(turnsText, contentX + colName + colStatus + colSolved + colAttempts + 6, rowY + 9, colTurns - 10, "left")

            love.graphics.setColor(1, 1, 1, 0.08)
            love.graphics.rectangle("fill", contentX + 2, rowY + LAYOUT.rowHeight - 1, contentW - 4, 1)
        end
    end

    local scrollbar = scrollbarGeometry()
    love.graphics.setColor(0.24, 0.24, 0.24, 0.9)
    love.graphics.rectangle("fill", scrollbar.trackX, scrollbar.trackY, LAYOUT.scrollbarWidth, scrollbar.trackHeight, 4, 4)
    if scrollbar.visible then
        love.graphics.setColor(0.66, 0.67, 0.70, 0.95)
        love.graphics.rectangle("fill", scrollbar.trackX + 1, scrollbar.thumbY + 1, LAYOUT.scrollbarWidth - 2, scrollbar.thumbHeight - 2, 4, 4)
    end

    for _, button in ipairs(buttonOrder) do
        uiTheme.drawButton(button)
    end

    if ConfirmDialog and ConfirmDialog.draw then
        ConfirmDialog.draw()
    end

    love.graphics.pop()
end

function scenarioSelect.mousemoved(x, y, dx, dy, istouch)
    if ConfirmDialog.isActive() then
        ConfirmDialog.mousemoved(x, y)
        return
    end

    local tx = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    if scrollbarDragging then
        local scrollbar = scrollbarGeometry()
        if scrollbar.visible and scrollbar.thumbTravel > 0 and scrollbar.maxOffset > 0 then
            local deltaY = ty - scrollbarDragAnchorY
            local ratio = deltaY / scrollbar.thumbTravel
            local targetOffset = scrollbarDragAnchorOffset + ratio * scrollbar.maxOffset
            setScrollOffsetRows(targetOffset)
        end
        updateButtonStates()
        return
    end

    local hoveredTarget = nil
    local rowIndex = rowIndexAt(tx, ty)
    if rowIndex then
        setSelectedRowIndex(rowIndex)
        listFocus = true
        hoveredTarget = "row:" .. tostring(rowIndex)
    else
        for i, button in ipairs(buttonOrder) do
            if button.enabled and isMouseOverButton(button, tx, ty) then
                selectedButtonIndex = i
                listFocus = false
                hoveredTarget = "button:" .. tostring(i)
                break
            end
        end
    end

    if hoveredTarget and hoveredTarget ~= lastHoveredTarget then
        playHoverSound()
    end
    lastHoveredTarget = hoveredTarget

    updateButtonStates()
end

function scenarioSelect.mousepressed(x, y, button, istouch, presses)
    if button ~= 1 then
        return
    end

    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousepressed(x, y, button)
    end

    local tx = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    local scrollbar = scrollbarGeometry()
    if scrollbar.visible then
        local inTrack = tx >= scrollbar.trackX and tx <= scrollbar.trackX + LAYOUT.scrollbarWidth and ty >= scrollbar.trackY and ty <= scrollbar.trackY + scrollbar.trackHeight
        local inThumb = inTrack and ty >= scrollbar.thumbY and ty <= scrollbar.thumbY + scrollbar.thumbHeight

        if inThumb then
            scrollbarDragging = true
            scrollbarDragAnchorY = ty
            scrollbarDragAnchorOffset = scrollOffsetRows
            return
        elseif inTrack then
            if ty < scrollbar.thumbY then
                scrollRows(-visibleRows())
            elseif ty > scrollbar.thumbY + scrollbar.thumbHeight then
                scrollRows(visibleRows())
            end
            updateButtonStates()
            return
        end
    end

    local rowIndex = rowIndexAt(tx, ty)
    if rowIndex then
        setSelectedRowIndex(rowIndex)
        listFocus = true
        playClickSound()
        activateScenario(rowIndex)
        updateButtonStates()
        return
    end

    for i, candidate in ipairs(buttonOrder) do
        if candidate.enabled and isMouseOverButton(candidate, tx, ty) then
            selectedButtonIndex = i
            listFocus = false
            lastHoveredTarget = "button:" .. tostring(i)
            triggerSelectedButton(candidate)
            return
        end
    end

    updateButtonStates()
end

function scenarioSelect.mousereleased(x, y, button, istouch, presses)
    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousereleased(x, y, button)
    end

    if button == 1 then
        scrollbarDragging = false
    end
end

function scenarioSelect.wheelmoved(dx, dy)
    if ConfirmDialog.isActive() then
        return
    end

    if dy ~= 0 then
        listFocus = true
        scrollRows(-dy)
        updateButtonStates()
    end
end

function scenarioSelect.keypressed(key, scancode, isrepeat)
    if ConfirmDialog.isActive() then
        return ConfirmDialog.keypressed(key)
    end

    if key == "escape" then
        onBack()
        return true
    end

    if key == "tab" then
        listFocus = not listFocus
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "up" or key == "w" then
        if not listFocus then
            if #scenarioRows > 0 then
                listFocus = true
                clampSelection()
                updateButtonStates()
                playHoverSound()
                return true
            end
            return false
        end

        if #scenarioRows > 0 then
            local nextIndex = selectedRowIndex - 1
            if nextIndex < 1 then
                nextIndex = 1
            end
            if nextIndex ~= selectedRowIndex then
                setSelectedRowIndex(nextIndex)
                updateButtonStates()
                playHoverSound()
            end
            return true
        end
    end

    if key == "down" or key == "s" then
        if not listFocus then
            return true
        end

        if #scenarioRows > 0 then
            local nextIndex = selectedRowIndex + 1
            if nextIndex > #scenarioRows then
                listFocus = false
                ensureValidButtonSelection()
                updateButtonStates()
                playHoverSound()
                return true
            end
            setSelectedRowIndex(nextIndex)
            updateButtonStates()
            playHoverSound()
            return true
        end
    end

    if key == "pageup" then
        listFocus = true
        scrollRows(-visibleRows())
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "pagedown" then
        listFocus = true
        scrollRows(visibleRows())
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "left" or key == "a" or key == "q" then
        listFocus = false
        selectedButtonIndex = selectEnabledButton(selectedButtonIndex - 1, -1) or selectedButtonIndex
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "right" or key == "d" or key == "e" then
        listFocus = false
        selectedButtonIndex = selectEnabledButton(selectedButtonIndex + 1, 1) or selectedButtonIndex
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "return" or key == "space" then
        if listFocus and #scenarioRows > 0 then
            playClickSound()
            activateScenario(selectedRowIndex)
            return true
        end
        triggerSelectedButton(buttonOrder[selectedButtonIndex])
        updateButtonStates()
        return true
    end

    return false
end

function scenarioSelect.gamepadpressed(joystick, button)
    if button == "a" then
        return scenarioSelect.keypressed("return", "return", false)
    end
    if button == "b" or button == "back" then
        return scenarioSelect.keypressed("escape", "escape", false)
    end
    if button == "dpup" then
        return scenarioSelect.keypressed("up", "up", false)
    end
    if button == "dpdown" then
        return scenarioSelect.keypressed("down", "down", false)
    end
    if button == "dpleft" or button == "leftshoulder" then
        return scenarioSelect.keypressed("left", "left", false)
    end
    if button == "dpright" or button == "rightshoulder" then
        return scenarioSelect.keypressed("right", "right", false)
    end
    return false
end

return scenarioSelect
