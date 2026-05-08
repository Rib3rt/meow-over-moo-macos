local scenarioEditor = {}

-- SCENARIO-ONLY SCREEN:
-- This editor must stay isolated from non-scenario modes.
-- Do not add behavior here that changes standard gameplay flows.

local uiTheme = require("uiTheme")
local soundCache = require("soundCache")
local unitsInfo = require("unitsInfo")
local ConfirmDialog = require("confirmDialog")

local stateMachineRef = nil

local uiButtons = {}
local buttonOrder = {}
local selectedButtonIndex = 1
local boardFocus = true
local lastHoveredTarget = nil

local selectedCell = { row = 1, col = 1 }
local selectedUnitIndex = nil

local DEFAULT_EDITOR_SCENARIO_CODE = "P003"
local DEFAULT_EDITOR_ROUND_LIMIT = 4

local scenarioCode = DEFAULT_EDITOR_SCENARIO_CODE
local scenarioRoundLimit = DEFAULT_EDITOR_ROUND_LIMIT
local scenarioTagIndex = 2
local scenarioComplexityIndex = 3

local scenarioTagValues = {"Low", "Medium", "High"}
local scenarioComplexityValues = {"Low", "Medium", "High"}

local editorUnits = {}
local editorLogLines = {}
local unitSpriteCache = {}
local editorInitialized = false
local editorDefaultPresetKey = nil
local editorScenarioAttempts = 0
local editorGeneratedDossier = nil
local editorGeneratedQuality = nil
local editorBoardDirtySinceDossier = false
local editorBoardDirtyReason = nil
local scenarioExportCounter = 0
local editorGenerationJob = nil
local editorGenerationSerial = 0

local statusText = "Editor ready."
local statusSeverity = "info"
local getUnitBaseHp
local selectCell

local SCENARIO_RUNTIME_ACTION_BUDGET = 2
local SCENARIO_DOSSIER_DIR = "scenario_dossiers"
local SCENARIO_SOLUTION_DIR = "scenario_solutions"
local SCENARIO_EXPORT_STATUS = "PROMOTED"
local SCENARIO_NEW_GENERATOR_MAX_ATTEMPTS = 48
local SCENARIO_NEW_GENERATOR_SOLVER_MAX_NODES = 9000
local SCENARIO_GENERATION_WORKER_PATH = "scenario_tooling/editor_generation_worker.lua"
local generatorArchetypes = {
    { archetype = "support_intercepts_finisher_threat_artillery_finish", label = "Support intercepts artillery" }
}

local BUTTON_BEEP_SOUND_PATH = "assets/audio/GenericButton14.wav"
local BUTTON_CLICK_SOUND_PATH = "assets/audio/GenericButton6.wav"

local UNIT_CYCLE = {
    "Wingstalker",
    "Crusher",
    "Bastion",
    "Cloudstriker",
    "Earthstalker",
    "Healer",
    "Artillery"
}

local BOARD_LETTERS = {"A", "B", "C", "D", "E", "F", "G", "H"}

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

local function canonicalExportAction(action)
    if type(action) ~= "table" then
        return nil
    end

    local actionType = action.type
    if actionType == nil then
        return nil
    end

    local out = {
        type = actionType,
        actorId = action.actorId,
        targetId = action.targetId,
        id = action.id
    }
    if type(action.from) == "table" then
        out.from = {
            row = tonumber(action.from.row),
            col = tonumber(action.from.col)
        }
    end
    if type(action.to) == "table" then
        out.to = {
            row = tonumber(action.to.row),
            col = tonumber(action.to.col)
        }
    end
    if type(action.targetCell) == "table" then
        out.targetCell = {
            row = tonumber(action.targetCell.row),
            col = tonumber(action.targetCell.col)
        }
    end
    return out
end

local function canonicalExportActionList(actions)
    local out = {}
    for _, action in ipairs(actions or {}) do
        local canonical = canonicalExportAction(action)
        if canonical then
            out[#out + 1] = canonical
        end
    end
    return out
end

local function buildLayout()
    local margin = 24
    local top = 56
    local bottom = 24
    local height = SETTINGS.DISPLAY.HEIGHT - top - bottom

    local leftPanel = {
        x = margin,
        y = top,
        width = 620,
        height = height
    }

    local rightPanel = {
        x = leftPanel.x + leftPanel.width + 18,
        y = top,
        width = SETTINGS.DISPLAY.WIDTH - (margin * 2) - leftPanel.width - 18,
        height = height
    }

    local board = {
        cellSize = 64,
        gridSize = 8
    }
    board.pixelSize = board.cellSize * board.gridSize
    board.x = leftPanel.x + math.floor((leftPanel.width - board.pixelSize) / 2)
    board.y = leftPanel.y + 60

    local bottomButtons = {
        x = leftPanel.x + 20,
        y = leftPanel.y + leftPanel.height - 62,
        width = leftPanel.width - 40,
        height = 42,
        gap = 12
    }
    bottomButtons.buttonWidth = math.floor((bottomButtons.width - (bottomButtons.gap * 3)) / 4)

    local rightPadding = 14
    local sectionGap = 10

    local sectionScenario = {
        x = rightPanel.x + rightPadding,
        y = rightPanel.y + 14,
        width = rightPanel.width - (rightPadding * 2),
        height = 164
    }

    local sectionSelected = {
        x = sectionScenario.x,
        y = sectionScenario.y + sectionScenario.height + sectionGap,
        width = sectionScenario.width,
        height = 118
    }

    local sectionConfig = {
        x = sectionScenario.x,
        y = sectionSelected.y + sectionSelected.height + sectionGap,
        width = sectionScenario.width,
        height = 178
    }

    local sectionLog = {
        x = sectionScenario.x,
        y = sectionConfig.y + sectionConfig.height + sectionGap,
        width = sectionScenario.width,
        height = rightPanel.y + rightPanel.height - (sectionConfig.y + sectionConfig.height + sectionGap) - 14
    }

    return {
        leftPanel = leftPanel,
        rightPanel = rightPanel,
        board = board,
        bottomButtons = bottomButtons,
        sectionScenario = sectionScenario,
        sectionSelected = sectionSelected,
        sectionConfig = sectionConfig,
        sectionLog = sectionLog
    }
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

local function setStatus(message, severity)
    statusText = tostring(message or "")
    statusSeverity = severity or "info"
end

local function getStatusColor()
    if statusSeverity == "error" then
        return 0.84, 0.36, 0.36, 0.95
    end
    if statusSeverity == "ok" then
        return 0.44, 0.76, 0.54, 0.95
    end
    if statusSeverity == "warn" then
        return 0.90, 0.74, 0.42, 0.95
    end
    return 0.74, 0.78, 0.84, 0.95
end

local function appendLog(line)
    editorLogLines[#editorLogLines + 1] = tostring(line or "")
    while #editorLogLines > 7 do
        table.remove(editorLogLines, 1)
    end
end

local function markEditorBoardDirty(reason)
    if editorGeneratedDossier == nil then
        return
    end

    editorBoardDirtySinceDossier = true
    editorBoardDirtyReason = tostring(reason or "manual_edit")
end

local function scenarioTrace(scope, message)
    print("[SCENARIO_TRACE][" .. tostring(scope or "Editor") .. "] " .. tostring(message or ""))
end

local function countUnitGroups(units)
    local counts = {
        total = 0,
        blue = 0,
        red = 0,
        neutral = 0,
        redCommandants = 0,
        activeRed = 0
    }
    for _, unit in ipairs(units or {}) do
        local player = tonumber(unit.player)
        local name = tostring(unit.name or "")
        counts.total = counts.total + 1
        if player == 1 then
            counts.blue = counts.blue + 1
        elseif player == 2 then
            counts.red = counts.red + 1
            if name == "Commandant" then
                counts.redCommandants = counts.redCommandants + 1
            else
                counts.activeRed = counts.activeRed + 1
            end
        else
            counts.neutral = counts.neutral + 1
        end
    end
    return counts
end

local function traceUnitList(scope, label, units)
    local counts = countUnitGroups(units)
    scenarioTrace(scope, string.format(
        "%s count=%d blue=%d red=%d activeRed=%d redCommandants=%d neutral=%d",
        tostring(label),
        counts.total,
        counts.blue,
        counts.red,
        counts.activeRed,
        counts.redCommandants,
        counts.neutral
    ))
    for index, unit in ipairs(units or {}) do
        scenarioTrace(scope, string.format(
            "%s[%d] id=%s name=%s player=%s cell=%s,%s hp=%s/%s acted=%s",
            tostring(label),
            index,
            tostring(unit.scenarioUnitId or unit.id or ""),
            tostring(unit.name or ""),
            tostring(unit.player or ""),
            tostring(unit.row or ""),
            tostring(unit.col or ""),
            tostring(unit.currentHp or unit.hp or ""),
            tostring(unit.startingHp or ""),
            tostring(unit.hasActed or unit.acted or false)
        ))
    end
end

local function traceScenarioPolicyConfig(scope, label, config)
    config = type(config) == "table" and config or {}
    scenarioTrace(scope, string.format(
        "%s seed=%s requiredCells=%d criticalBlueUnitIds=%d",
        tostring(label),
        tostring(config.seed or ""),
        #(config.requiredCells or {}),
        #(config.criticalBlueUnitIds or {})
    ))
end

local function traceGeneratedDossier(seed, dossier, quality)
    scenarioTrace("Editor", string.format(
        "new_scenario.result seed=%s id=%s pipeline=%s quality=%s proof=%s falseLines=%d",
        tostring(seed),
        tostring(dossier and dossier.id or ""),
        tostring(dossier and dossier.pipelineState or ""),
        tostring(quality and quality.status or ""),
        tostring(dossier and dossier.solverProof and dossier.solverProof.status or ""),
        #(dossier and dossier.falseLines or {})
    ))
    traceUnitList("Editor", "generated_state.units", dossier and dossier.scenarioState and dossier.scenarioState.units or {})
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
        if player ~= 0 and player ~= 1 and player ~= 2 then
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

local function makeScenarioUnitId(unit, index)
    local player = tonumber(unit and unit.player) or 0
    if player ~= 1 and player ~= 2 then
        player = 0
    end
    local name = tostring(unit and unit.name or "unit"):gsub("%W+", "_"):lower()
    local row = math.floor(tonumber(unit and unit.row) or 0)
    local col = math.floor(tonumber(unit and unit.col) or 0)
    return table.concat({
        "editor",
        tostring(player),
        name,
        tostring(row),
        tostring(col),
        tostring(index or 0)
    }, "_")
end

local function normalizeScenarioCode(rawCode)
    local value = tostring(rawCode or "P002")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return "P002"
    end
    return value
end

local function clearOnlineRuntime()
    if not (GAME and GAME.CURRENT) then
        return
    end
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

local function createButton(name, text, x, y, width, height, variantName)
    local button = {
        name = name,
        text = text,
        x = x,
        y = y,
        width = width,
        height = height,
        enabled = true,
        focused = false,
        hovered = false,
        variantName = variantName or "default",
        centerText = true
    }
    uiTheme.applyButtonVariant(button, button.variantName)
    button.currentColor = button.baseColor
    return button
end

local function buildDefaultEditorUnits()
    return {
        {scenarioUnitId = "blue_finisher", name = "Crusher", player = 1, row = 6, col = 8, hp = 4},
        {scenarioUnitId = "blue_bait", name = "Bastion", player = 1, row = 8, col = 4, hp = 3},
        {scenarioUnitId = "blue_interceptor", name = "Earthstalker", player = 1, row = 7, col = 5, hp = 3},
        {scenarioUnitId = "blue_false_decoy", name = "Wingstalker", player = 1, row = 8, col = 3, hp = 3},
        {scenarioUnitId = "red_commandant", name = "Commandant", player = 2, row = 2, col = 4, hp = 4},
        {scenarioUnitId = "red_hunter", name = "Earthstalker", player = 2, row = 6, col = 4, hp = 3},
        {scenarioUnitId = "red_sniper", name = "Cloudstriker", player = 2, row = 6, col = 3, hp = 4},
        {scenarioUnitId = "red_guard", name = "Wingstalker", player = 2, row = 5, col = 1, hp = 3}
    }
end

local function buildDefaultEditorPresetKey()
    local parts = {
        normalizeScenarioCode(scenarioCode),
        tostring(math.max(1, math.floor(tonumber(scenarioRoundLimit) or 1)))
    }
    local defaults = buildDefaultEditorUnits()
    for _, unit in ipairs(defaults) do
        parts[#parts + 1] = table.concat({
            tostring(unit.scenarioUnitId or ""),
            tostring(unit.name or ""),
            tostring(unit.player or ""),
            tostring(unit.row or ""),
            tostring(unit.col or ""),
            tostring(unit.hp or "")
        }, ":")
    end
    return table.concat(parts, "|")
end

local function nextGeneratedScenarioSeed()
    local base = os.time and os.time() or 1
    local unitFactor = (#editorUnits + 1) * 97
    local roundFactor = math.max(1, math.floor(tonumber(scenarioRoundLimit) or 3)) * 131
    local serialFactor = math.max(1, editorGenerationSerial) * 1000003
    local timerFactor = 0
    if love and love.timer and type(love.timer.getTime) == "function" then
        timerFactor = math.floor((love.timer.getTime() * 1000000) % 1000000)
    end
    return math.max(1, math.floor(base + unitFactor + roundFactor + serialFactor + timerFactor))
end

local function isGenerationActive()
    return type(editorGenerationJob) == "table" and editorGenerationJob.active == true
end

local function randomGeneratorIndex(maxValue)
    maxValue = math.max(1, math.floor(tonumber(maxValue) or 1))
    if love and love.math and type(love.math.random) == "function" then
        local ok, value = pcall(love.math.random, maxValue)
        if ok and tonumber(value) then
            return math.max(1, math.min(maxValue, math.floor(value)))
        end
    end
    return math.max(1, math.min(maxValue, math.floor(math.random(maxValue))))
end

local function generatorProfileForAttempt(job)
    local count = #generatorArchetypes
    if count <= 0 then
        return nil, 0
    end
    local startIndex = math.max(1, math.floor(tonumber(job and job.profileStartIndex) or 1))
    local attempt = math.max(1, math.floor(tonumber(job and job.attempt) or 1))
    local index = ((startIndex + attempt - 2) % count) + 1
    return generatorArchetypes[index], index
end

local function hasActiveRedUnit(units)
    for _, unit in ipairs(units or {}) do
        local hp = tonumber(unit.currentHp) or tonumber(unit.hp) or 0
        if hp > 0 and tonumber(unit.player) == 2 and tostring(unit.name or "") ~= "Commandant" then
            return true
        end
    end
    return false
end

local function stableString(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function liveBlueUnitIds(units)
    local ids = {}
    for index, unit in ipairs(units or {}) do
        local hp = tonumber(unit.currentHp) or tonumber(unit.hp) or 0
        if hp > 0 and tonumber(unit.player) == 1 then
            local id = stableString(unit.scenarioUnitId or unit.id or index)
            if id ~= "" then
                ids[id] = true
            end
        end
    end
    return ids
end

local function blueCoordinationContract(actions, blueActorIds, finisherId)
    local supportActions = 0
    local finisherActions = 0
    local supportActors = {}
    local firstBlueAction = nil
    local supportAttackBeforePayoff = false
    local finisherPayoff = false
    finisherId = stableString(finisherId or "blue_finisher")

    for _, action in ipairs(actions or {}) do
        if type(action) == "table" then
            local actor = stableString(action.actorId)
            local isBlueActor = blueActorIds[actor] == true
            if isBlueActor and actor ~= finisherId then
                supportActions = supportActions + 1
                supportActors[actor] = true
                firstBlueAction = firstBlueAction or action
                if action.type == "attack" and not finisherPayoff then
                    supportAttackBeforePayoff = true
                end
            elseif isBlueActor and actor == finisherId then
                finisherActions = finisherActions + 1
                firstBlueAction = firstBlueAction or action
                if action.type == "attack" and action.targetId == "red_commandant" then
                    finisherPayoff = true
                end
            end
        end
    end

    local supportActorCount = 0
    for _ in pairs(supportActors) do
        supportActorCount = supportActorCount + 1
    end

    return {
        pass = supportActions >= 2
            and finisherActions >= 2
            and type(firstBlueAction) == "table"
            and blueActorIds[stableString(firstBlueAction.actorId)] == true
            and stableString(firstBlueAction.actorId) ~= finisherId
            and firstBlueAction.type == "move"
            and supportAttackBeforePayoff == true
            and finisherPayoff == true,
        supportActions = supportActions,
        supportActors = supportActorCount,
        finisherActions = finisherActions,
        firstBlueActor = firstBlueAction and firstBlueAction.actorId or nil,
        firstBlueActionType = firstBlueAction and firstBlueAction.type or nil,
        supportAttackBeforePayoff = supportAttackBeforePayoff,
        finisherPayoff = finisherPayoff
    }
end

local function generatedDossierHasBlueCoordination(dossier)
    local blueActorIds = liveBlueUnitIds(dossier and dossier.scenarioState and dossier.scenarioState.units or {})
    local solutionActions = dossier and dossier.solution and dossier.solution.actions or {}
    local report = blueCoordinationContract(solutionActions, blueActorIds, "blue_finisher")
    if report.pass then
        return true, report
    end

    local proofActions = dossier and dossier.solverProof and dossier.solverProof.winningLine or {}
    report = blueCoordinationContract(proofActions, blueActorIds, "blue_finisher")
    return report.pass == true, report
end

local function clearChannel(channel)
    if not channel then
        return
    end
    if type(channel.clear) == "function" then
        pcall(channel.clear, channel)
        return
    end
    while channel:pop() ~= nil do
    end
end

local function startScenarioGenerationThread(job)
    if not (love and love.thread and type(love.thread.newThread) == "function" and type(love.thread.getChannel) == "function") then
        return false, "love_thread_unavailable"
    end

    local token = "scenario_editor_generation_" .. tostring(editorGenerationSerial)
    local requestChannelName = token .. "_request"
    local responseChannelName = token .. "_response"
    local cancelChannelName = token .. "_cancel"
    local requestChannel = love.thread.getChannel(requestChannelName)
    local responseChannel = love.thread.getChannel(responseChannelName)
    local cancelChannel = love.thread.getChannel(cancelChannelName)
    clearChannel(requestChannel)
    clearChannel(responseChannel)
    clearChannel(cancelChannel)

    local okThread, threadOrErr = pcall(love.thread.newThread, SCENARIO_GENERATION_WORKER_PATH)
    if not okThread or not threadOrErr then
        return false, tostring(threadOrErr or "thread_create_failed")
    end

    job.mode = "thread"
    job.token = token
    job.thread = threadOrErr
    job.responseChannel = responseChannel
    job.cancelChannel = cancelChannel
    requestChannel:push({
        token = token,
        seedBase = job.seedBase,
        maxAttempts = job.maxAttempts,
        profileStartIndex = job.profileStartIndex,
        solverMaxNodes = SCENARIO_NEW_GENERATOR_SOLVER_MAX_NODES,
        profiles = cloneValue(generatorArchetypes)
    })

    local okStart, startErr = pcall(function()
        threadOrErr:start(requestChannelName, responseChannelName, cancelChannelName)
    end)
    if not okStart then
        job.mode = "inline"
        return false, tostring(startErr or "thread_start_failed")
    end
    return true
end

local function reasonCodesFromQuality(result)
    local codes = {}
    local function collect(list)
        for _, entry in ipairs(list or {}) do
            local code = type(entry) == "table" and entry.code or entry
            if code ~= nil then
                codes[#codes + 1] = tostring(code)
            end
        end
    end
    collect(result and result.reasons)
    collect(result and result.unknowns)
    if #codes == 0 then
        return "no_quality_reason"
    end
    return table.concat(codes, ", ")
end

local function loadGeneratedScenarioIntoEditor(dossier, quality)
    local state = dossier and dossier.scenarioState or nil
    if type(state) ~= "table" or type(state.units) ~= "table" then
        return false, "missing_generated_state"
    end

    local loadedUnits = {}
    for _, unit in ipairs(state.units) do
        local name = tostring(unit.name or "")
        local row = math.floor(tonumber(unit.row) or 0)
        local col = math.floor(tonumber(unit.col) or 0)
        if name ~= "" and row >= 1 and row <= 8 and col >= 1 and col <= 8 then
            local player = tonumber(unit.player) or 0
            if name == "Rock" then
                player = 0
            elseif player ~= 1 and player ~= 2 then
                player = 1
            end
            loadedUnits[#loadedUnits + 1] = {
                scenarioUnitId = unit.scenarioUnitId or unit.id,
                name = name,
                player = player,
                row = row,
                col = col,
                hp = math.max(1, math.floor(tonumber(unit.currentHp) or tonumber(unit.startingHp) or getUnitBaseHp(name))),
                acted = unit.hasActed == true
            }
        end
    end

    if #loadedUnits == 0 then
        return false, "generated_state_has_no_units"
    end
    if not hasActiveRedUnit(loadedUnits) then
        return false, "generated_state_has_no_active_red_unit"
    end
    local hasCoordination = generatedDossierHasBlueCoordination(dossier)
    if not hasCoordination then
        return false, "generated_state_lacks_blue_coordination"
    end

    editorUnits = loadedUnits
    editorGeneratedDossier = cloneValue(dossier)
    editorGeneratedQuality = cloneValue(quality)
    editorBoardDirtySinceDossier = false
    editorBoardDirtyReason = nil
    scenarioCode = normalizeScenarioCode(dossier.id or ("G" .. tostring(dossier.seed or "")))
    scenarioRoundLimit = math.max(1, math.floor(tonumber(state.turnLimit) or tonumber(dossier.turnLimit) or 3))
    editorScenarioAttempts = 0
    selectedUnitIndex = nil
    selectCell(1, 1)
    return true
end

local function findUnitIndexAt(row, col)
    for index, unit in ipairs(editorUnits) do
        if unit.row == row and unit.col == col then
            return index
        end
    end
    return nil
end

local function getSelectedUnit()
    if selectedUnitIndex and editorUnits[selectedUnitIndex] then
        return editorUnits[selectedUnitIndex], selectedUnitIndex
    end
    return nil, nil
end

getUnitBaseHp = function(unitName)
    local info = unitsInfo and unitsInfo.getUnitInfo and unitsInfo:getUnitInfo(unitName) or nil
    local hp = info and tonumber(info.startingHp or info.hp) or nil
    if hp and hp > 0 then
        return math.floor(hp)
    end
    return 1
end

local function buildRuntimeScenarioSnapshotFromEditor()
    local boardUnits = {}
    local commandHubPositions = {}
    local occupiedCells = {}
    local redCommandantIndex = nil
    local firstRedUnitIndex = nil
    local blueUnitCount = 0

    for sourceIndex, rawUnit in ipairs(editorUnits) do
        local row = math.floor(tonumber(rawUnit.row) or 0)
        local col = math.floor(tonumber(rawUnit.col) or 0)
        local name = tostring(rawUnit.name or "")
        if row >= 1 and row <= 8 and col >= 1 and col <= 8 and name ~= "" then
            local key = tostring(row) .. ":" .. tostring(col)
            if occupiedCells[key] then
                return nil, "duplicate_cell"
            end
            occupiedCells[key] = true

            local player = tonumber(rawUnit.player)
            if name == "Rock" then
                player = 0
            elseif player ~= 1 and player ~= 2 then
                player = 1
            end
            if player == 0 and name ~= "Rock" then
                player = 1
            end

            -- Scenario runtime normalization:
            -- keep editor flexible, but force playable constraints in runtime snapshot only.
            if name == "Commandant" and player == 1 then
                name = "Bastion"
            end

            local baseHp = getUnitBaseHp(name)
            local currentHp = math.floor(tonumber(rawUnit.hp) or baseHp)
            currentHp = math.max(1, math.min(baseHp, currentHp))

            local unitEntry = {
                scenarioUnitId = rawUnit.scenarioUnitId or rawUnit.id or makeScenarioUnitId({
                    name = name,
                    player = player,
                    row = row,
                    col = col
                }, sourceIndex),
                row = row,
                col = col,
                name = name,
                player = player,
                currentHp = currentHp,
                startingHp = baseHp,
                hasActed = rawUnit.acted == true,
                turnActions = {}
            }
            boardUnits[#boardUnits + 1] = unitEntry
            local unitIndex = #boardUnits

            if player == 1 and name ~= "Rock" then
                blueUnitCount = blueUnitCount + 1
            end

            if player == 2 and name ~= "Rock" and not firstRedUnitIndex then
                firstRedUnitIndex = unitIndex
            end

            if name == "Commandant" and player == 2 then
                if not redCommandantIndex then
                    redCommandantIndex = unitIndex
                    commandHubPositions[2] = { row = row, col = col }
                else
                    unitEntry.name = "Bastion"
                    unitEntry.startingHp = getUnitBaseHp("Bastion")
                    unitEntry.currentHp = math.max(1, math.floor(tonumber(rawUnit.hp) or unitEntry.startingHp))
                end
            end
        end
    end

    if #boardUnits == 0 then
        return nil, "empty_board"
    end
    local function findFirstFreeCell()
        for candidateRow = 1, 8 do
            for candidateCol = 1, 8 do
                local key = tostring(candidateRow) .. ":" .. tostring(candidateCol)
                if not occupiedCells[key] then
                    return candidateRow, candidateCol, key
                end
            end
        end
        return nil, nil, nil
    end

    if not redCommandantIndex then
        if firstRedUnitIndex and boardUnits[firstRedUnitIndex] then
            local promoted = boardUnits[firstRedUnitIndex]
            promoted.name = "Commandant"
            promoted.startingHp = getUnitBaseHp("Commandant")
            promoted.currentHp = math.max(1, math.floor(tonumber(promoted.currentHp) or promoted.startingHp))
            redCommandantIndex = firstRedUnitIndex
            commandHubPositions[2] = { row = promoted.row, col = promoted.col }
        else
            local row, col, key = findFirstFreeCell()
            if not row or not col then
                return nil, "missing_red_commandant"
            end
            occupiedCells[key] = true
            local hp = getUnitBaseHp("Commandant")
            boardUnits[#boardUnits + 1] = {
                row = row,
                col = col,
                name = "Commandant",
                player = 2,
                currentHp = hp,
                startingHp = hp,
                hasActed = false,
                turnActions = {}
            }
            redCommandantIndex = #boardUnits
            commandHubPositions[2] = { row = row, col = col }
        end
    end

    if blueUnitCount <= 0 then
        local row, col, key = findFirstFreeCell()
        if row and col then
            occupiedCells[key] = true
            local hp = getUnitBaseHp("Bastion")
            boardUnits[#boardUnits + 1] = {
                row = row,
                col = col,
                name = "Bastion",
                player = 1,
                currentHp = hp,
                startingHp = hp,
                hasActed = false,
                turnActions = {}
            }
            blueUnitCount = blueUnitCount + 1
        else
            return nil, "missing_blue_units"
        end
    end

    local turnOrder = cloneSequence((GAME and GAME.CURRENT and GAME.CURRENT.TURN_ORDER) or {1, 2})
    if #turnOrder == 0 then
        turnOrder = {1, 2}
    end

    local factionAssignments = cloneMap((GAME and GAME.CURRENT and GAME.CURRENT.FACTION_ASSIGNMENTS) or {
        [1] = "local_player_1",
        [2] = "local_ai_1"
    })

    local integritySignature = computeScenarioIntegritySignature(boardUnits)
    local seed = 13001 + #boardUnits + math.max(1, math.floor(tonumber(scenarioRoundLimit) or 1))
    return {
        version = 4,
        currentPhase = "turn",
        currentTurnPhase = "actions",
        currentTurn = 1,
        currentPlayer = 1,
        turnOrder = turnOrder,
        factionAssignments = factionAssignments,
        winner = nil,
        maxActionsPerTurn = SCENARIO_RUNTIME_ACTION_BUDGET,
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
        logicRngSeed = seed,
        logicRngState = seed,
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

local function formatSnapshotBuildError(reason)
    if reason == "empty_board" then
        return "board is empty."
    end
    if reason == "missing_red_commandant" then
        return "no slot available to place a Red Commandant."
    end
    if reason == "missing_blue_units" then
        return "at least one Blue unit is required."
    end
    if reason == "duplicate_cell" then
        return "multiple units are on the same cell."
    end
    return tostring(reason or "invalid_scenario")
end

local function buildScenarioRedPolicyConfig()
    local okPolicy, runtimePolicy = pcall(require, "scenarioRedPolicy")
    local dossier = editorGeneratedDossier
    local config = type(dossier) == "table" and type(dossier.scenarioRedPolicy) == "table"
        and cloneValue(dossier.scenarioRedPolicy)
        or {
        runtime = "scenarioRedRuntime",
        policy = "scenarioRedPolicy",
        policyVersion = okPolicy and runtimePolicy.VERSION or "scenario_red_policy.v2",
        policyHash = okPolicy and runtimePolicy.POLICY_HASH or nil,
        seed = scenarioCode,
        requiredCells = {},
        criticalBlueUnitIds = { "blue_finisher" }
    }

    config.runtime = config.runtime or "scenarioRedRuntime"
    config.policy = config.policy or "scenarioRedPolicy"
    config.policyVersion = config.policyVersion or (okPolicy and runtimePolicy.VERSION or "scenario_red_policy.v2")
    config.policyHash = config.policyHash or (okPolicy and runtimePolicy.POLICY_HASH or nil)
    config.requiredCells = type(config.requiredCells) == "table" and config.requiredCells or {}
    config.criticalBlueUnitIds = type(config.criticalBlueUnitIds) == "table" and config.criticalBlueUnitIds or { "blue_finisher" }

    if type(dossier) == "table" then
        config.seed = dossier.seed or dossier.id or scenarioCode
        local seenCells = {}
        for _, cell in ipairs(config.requiredCells) do
            if type(cell) == "table" then
                local row = tonumber(cell.row)
                local col = tonumber(cell.col)
                if row and col then
                    seenCells[tostring(row) .. ":" .. tostring(col)] = true
                end
            end
        end
        for _, action in ipairs(dossier.solution and dossier.solution.actions or {}) do
            local to = action and action.to
            if type(to) == "table" then
                local row = tonumber(to.row)
                local col = tonumber(to.col)
                if row and col then
                    local key = tostring(row) .. ":" .. tostring(col)
                    if not seenCells[key] then
                        seenCells[key] = true
                        config.requiredCells[#config.requiredCells + 1] = { row = row, col = col }
                    end
                end
            end
        end
    end

    return config
end

local function getUnitSpritePath(unit)
    if not unit or type(unit.name) ~= "string" then
        return nil
    end
    local info = unitsInfo and unitsInfo.getUnitInfo and unitsInfo:getUnitInfo(unit.name) or nil
    if type(info) ~= "table" then
        return nil
    end
    if unit.player == 2 then
        return info.pathUiIconRed or info.pathRed or info.pathUiIcon or info.path
    end
    return info.pathUiIcon or info.path
end

local function getUnitSprite(unit)
    local path = getUnitSpritePath(unit)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    if unitSpriteCache[path] ~= nil then
        return unitSpriteCache[path] or nil
    end
    local ok, image = pcall(love.graphics.newImage, path)
    if ok and image then
        unitSpriteCache[path] = image
        return image
    end
    unitSpriteCache[path] = false
    return nil
end

selectCell = function(row, col)
    selectedCell.row = math.max(1, math.min(8, math.floor(tonumber(row) or 1)))
    selectedCell.col = math.max(1, math.min(8, math.floor(tonumber(col) or 1)))
end

local function updateDynamicButtonLabels(selectedUnit, selectedCellUnitIndex)
    if uiButtons.roundMinus then
        uiButtons.roundMinus.text = "Round -"
    end
    if uiButtons.roundPlus then
        uiButtons.roundPlus.text = "Round +"
    end
    if uiButtons.tagButton then
        uiButtons.tagButton.text = "Tag: " .. tostring(scenarioTagValues[scenarioTagIndex] or "Medium")
    end
    if uiButtons.complexityButton then
        uiButtons.complexityButton.text = "Complexity: " .. tostring(scenarioComplexityValues[scenarioComplexityIndex] or "High")
    end
    if uiButtons.cycleUnit then
        if selectedUnit then
            uiButtons.cycleUnit.text = "Cycle Unit"
        elseif not selectedCellUnitIndex then
            uiButtons.cycleUnit.text = "Add Unit"
        else
            uiButtons.cycleUnit.text = "Cycle Unit"
        end
    end
end

local function updateButtonStates()
    local selectedUnit = getSelectedUnit()
    local selectedCellUnitIndex = findUnitIndexAt(selectedCell.row, selectedCell.col)
    local selectedIsRedCommandant = selectedUnit and selectedUnit.name == "Commandant" and tonumber(selectedUnit.player) == 2
    local generationActive = isGenerationActive()

    if uiButtons.newScenario then
        uiButtons.newScenario.text = generationActive and "Generating..." or "New Scenario"
    end

    if uiButtons.back then uiButtons.back.enabled = true end
    if uiButtons.newScenario then uiButtons.newScenario.enabled = true end
    if uiButtons.simulate then uiButtons.simulate.enabled = true end
    if uiButtons.export then uiButtons.export.enabled = true end
    if uiButtons.roundMinus then uiButtons.roundMinus.enabled = true end
    if uiButtons.roundPlus then uiButtons.roundPlus.enabled = true end
    if uiButtons.tagButton then uiButtons.tagButton.enabled = true end
    if uiButtons.complexityButton then uiButtons.complexityButton.enabled = true end
    if uiButtons.changeFaction then uiButtons.changeFaction.enabled = selectedUnit ~= nil end
    if uiButtons.cycleUnit then
        uiButtons.cycleUnit.enabled = (selectedCellUnitIndex == nil) or ((selectedUnit ~= nil) and (not selectedIsRedCommandant))
    end
    if uiButtons.addRock then uiButtons.addRock.enabled = selectedCellUnitIndex == nil end
    if uiButtons.addRedCmd then uiButtons.addRedCmd.enabled = true end
    if uiButtons.hpMinus then uiButtons.hpMinus.enabled = selectedUnit ~= nil end
    if uiButtons.hpPlus then uiButtons.hpPlus.enabled = selectedUnit ~= nil end
    if uiButtons.toggleActed then uiButtons.toggleActed.enabled = selectedUnit ~= nil end
    if uiButtons.removeUnit then uiButtons.removeUnit.enabled = selectedUnit ~= nil end

    updateDynamicButtonLabels(selectedUnit, selectedCellUnitIndex)

    if generationActive then
        for _, button in ipairs(buttonOrder) do
            button.enabled = (button == uiButtons.back)
        end
        selectedButtonIndex = 1
        boardFocus = false
    end

    for index, button in ipairs(buttonOrder) do
        local variant = (button.enabled ~= false) and (button.variantName or "default") or "disabled"
        uiTheme.applyButtonVariant(button, variant)
        button.focused = (not boardFocus) and (index == selectedButtonIndex) and button.enabled ~= false
        button.currentColor = button.focused and button.hoverColor or button.baseColor
        button.disabledVisual = button.enabled == false
    end
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
        local button = buttonOrder[index]
        if button and button.enabled ~= false then
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

local function initializeButtons()
    local layout = buildLayout()
    local bottom = layout.bottomButtons
    local y = bottom.y
    local h = bottom.height
    local x0 = bottom.x
    local w = bottom.buttonWidth
    local g = bottom.gap

    uiButtons.back = createButton("back", "Back", x0, y, w, h, "default")
    uiButtons.newScenario = createButton("newScenario", "New Scenario", x0 + w + g, y, w, h, "default")
    uiButtons.simulate = createButton("simulate", "Simulate", x0 + (w + g) * 2, y, w, h, "success")
    uiButtons.export = createButton("export", "Export", x0 + (w + g) * 3, y, w, h, "success")

    local section = layout.sectionScenario
    local innerX = section.x + 12
    local innerW = section.width - 24
    local miniGap = 10
    local miniW = math.floor((innerW - miniGap) / 2)
    local miniH = 30
    local miniRow1Y = section.y + section.height - 72
    local miniRow2Y = miniRow1Y + miniH + 6
    uiButtons.roundMinus = createButton("roundMinus", "Round -", innerX, miniRow1Y, miniW, miniH, "default")
    uiButtons.roundPlus = createButton("roundPlus", "Round +", innerX + miniW + miniGap, miniRow1Y, miniW, miniH, "default")
    uiButtons.tagButton = createButton("tagButton", "Tag: Medium", innerX, miniRow2Y, miniW, miniH, "default")
    uiButtons.complexityButton = createButton("complexityButton", "Complexity: High", innerX + miniW + miniGap, miniRow2Y, miniW, miniH, "default")

    local config = layout.sectionConfig
    local configPaddingX = 12
    local configGapX = 10
    local configGapY = 10
    local configCols = 3
    local configButtonW = math.floor((config.width - (configPaddingX * 2) - (configGapX * (configCols - 1))) / configCols)
    local configButtonH = 34
    local configStartY = config.y + 32

    local function configButtonPosition(col, row)
        return config.x + configPaddingX + (col - 1) * (configButtonW + configGapX),
            configStartY + (row - 1) * (configButtonH + configGapY)
    end

    local x, y1 = configButtonPosition(1, 1)
    uiButtons.changeFaction = createButton("changeFaction", "Change Faction", x, y1, configButtonW, configButtonH, "default")
    x, y1 = configButtonPosition(2, 1)
    uiButtons.cycleUnit = createButton("cycleUnit", "Cycle Unit", x, y1, configButtonW, configButtonH, "default")
    x, y1 = configButtonPosition(3, 1)
    uiButtons.addRock = createButton("addRock", "Add Rock", x, y1, configButtonW, configButtonH, "default")

    x, y1 = configButtonPosition(1, 2)
    uiButtons.addRedCmd = createButton("addRedCmd", "Add Red Cmd", x, y1, configButtonW, configButtonH, "default")
    x, y1 = configButtonPosition(2, 2)
    uiButtons.hpMinus = createButton("hpMinus", "HP -", x, y1, configButtonW, configButtonH, "default")
    x, y1 = configButtonPosition(3, 2)
    uiButtons.hpPlus = createButton("hpPlus", "HP +", x, y1, configButtonW, configButtonH, "default")

    x, y1 = configButtonPosition(1, 3)
    uiButtons.toggleActed = createButton("toggleActed", "Toggle Acted", x, y1, configButtonW, configButtonH, "default")
    x, y1 = configButtonPosition(2, 3)
    uiButtons.removeUnit = createButton("removeUnit", "Remove Unit", x, y1, configButtonW, configButtonH, "danger")

    buttonOrder = {
        uiButtons.back,
        uiButtons.newScenario,
        uiButtons.simulate,
        uiButtons.export,
        uiButtons.roundMinus,
        uiButtons.roundPlus,
        uiButtons.tagButton,
        uiButtons.complexityButton,
        uiButtons.changeFaction,
        uiButtons.cycleUnit,
        uiButtons.addRock,
        uiButtons.addRedCmd,
        uiButtons.hpMinus,
        uiButtons.hpPlus,
        uiButtons.toggleActed,
        uiButtons.removeUnit
    }

    selectedButtonIndex = 1
    boardFocus = true
end

local function onBack()
    if isGenerationActive() then
        if editorGenerationJob.mode == "thread" and editorGenerationJob.cancelChannel then
            pcall(function()
                editorGenerationJob.cancelChannel:push(true)
            end)
        end
        editorGenerationJob.cancelled = true
        editorGenerationJob = nil
        appendLog("- Scenario generation cancelled.")
        setStatus("Scenario generation cancelled.", "warn")
        updateButtonStates()
        return
    end

    if stateMachineRef then
        stateMachineRef.changeState("scenarioSelect")
    end
end

local function startNewScenarioGeneration()
    if isGenerationActive() then
        return
    end

    local okGenerator, retroGenerator = pcall(require, "scenario_tooling.retro_generator")
    local okQuality, qualityEvaluator = pcall(require, "scenario_tooling.quality_evaluator")
    if not okGenerator or type(retroGenerator) ~= "table" or type(retroGenerator.generate) ~= "function"
        or not okQuality or type(qualityEvaluator) ~= "table" or type(qualityEvaluator.evaluate) ~= "function" then
        appendLog("- Generator unavailable; board unchanged.")
        setStatus("Scenario generator unavailable.", "error")
        return
    end

    editorGenerationSerial = math.max(0, math.floor(tonumber(editorGenerationSerial) or 0)) + 1
    local seed = nextGeneratedScenarioSeed()
    editorGenerationJob = {
        active = true,
        cancelled = false,
        mode = "inline",
        attempt = 0,
        maxAttempts = SCENARIO_NEW_GENERATOR_MAX_ATTEMPTS,
        seedBase = seed,
        profileStartIndex = randomGeneratorIndex(#generatorArchetypes),
        retroGenerator = retroGenerator,
        qualityEvaluator = qualityEvaluator
    }
    local threadStarted, threadErr = startScenarioGenerationThread(editorGenerationJob)

    appendLog(string.format("- Generating scenario seed %d. Back cancels.", seed))
    if not threadStarted then
        scenarioTrace("Editor", "- new_scenario.thread_fallback reason=" .. tostring(threadErr))
    end
    scenarioTrace("Editor", string.format(
        "new_scenario.request seed=%d turnLimit=3 maxAttempts=%d profiles=%d",
        seed,
        SCENARIO_NEW_GENERATOR_MAX_ATTEMPTS,
        #generatorArchetypes
    ))
    setStatus("Generating scenario candidate... Back cancels.", "info")
    boardFocus = false
    selectedButtonIndex = 1
    updateButtonStates()
end

local function summarizeRejectedGeneration(dossier, quality)
    local qualityReasons = reasonCodesFromQuality(quality)
    if qualityReasons ~= "no_quality_reason" then
        return qualityReasons
    end

    local codes = {}
    for _, reason in ipairs(dossier and dossier.rejectionReasons or {}) do
        local code = type(reason) == "table" and reason.code or reason
        if code ~= nil then
            codes[#codes + 1] = tostring(code)
        end
    end
    if #codes > 0 then
        return table.concat(codes, ", ")
    end
    return "candidate_not_approved"
end

local function pollScenarioGenerationThread(job)
    if not (job and job.responseChannel) then
        editorGenerationJob = nil
        setStatus("Scenario generator worker unavailable.", "error")
        updateButtonStates()
        return true
    end

    local handledMessage = false
    while isGenerationActive() do
        local message = job.responseChannel:pop()
        if type(message) ~= "table" then
            break
        end
        if message.token == job.token then
            handledMessage = true
            local status = tostring(message.status or "")
            if status == "attempt" then
                job.attempt = tonumber(message.attempt) or job.attempt
                appendLog(string.format(
                    "- Try %02d/%02d: %s.",
                    tonumber(message.attempt) or 0,
                    tonumber(message.maxAttempts) or job.maxAttempts,
                    tostring(message.label or message.archetype or "profile")
                ))
                scenarioTrace("Editor", string.format(
                    "new_scenario.attempt attempt=%d seed=%d archetype=%s",
                    tonumber(message.attempt) or 0,
                    tonumber(message.seed) or 0,
                    tostring(message.archetype)
                ))
            elseif status == "rejected" then
                scenarioTrace("Editor", "- new_scenario.rejected reasons=" .. tostring(message.reason or "candidate_not_approved"))
            elseif status == "certified" then
                traceGeneratedDossier(message.seed, message.dossier, message.quality)
                local loaded, loadErr = loadGeneratedScenarioIntoEditor(message.dossier, message.quality)
                if loaded then
                    editorGenerationJob = nil
                    appendLog(string.format("- Generated %s loaded (%d units).", tostring(scenarioCode), #editorUnits))
                    appendLog(string.format("- Archetype: %s.", tostring(message.dossier.tacticalFingerprint and message.dossier.tacticalFingerprint.role_signature or message.archetype)))
                    if message.playtestOnly == true then
                        appendLog("- Editor playtest profile: not release-quality approved.")
                    end
                    appendLog(string.format("- Proof: %s, false lines: %d.", tostring(message.dossier.solverProof and message.dossier.solverProof.status or "unknown"), #(message.dossier.falseLines or {})))
                    traceUnitList("Editor", "editor.units_after_new_scenario", editorUnits)
                    setStatus("Generated scenario loaded into editor.", "ok")
                    updateButtonStates()
                    return true
                else
                    appendLog("- Generated candidate could not load: " .. tostring(loadErr))
                    scenarioTrace("Editor", "- new_scenario.load_rejected reason=" .. tostring(loadErr))
                    setStatus("Generating scenario candidate... Back cancels.", "info")
                end
            elseif status == "failed" then
                editorGenerationJob = nil
                appendLog("- Generated candidates rejected by gates.")
                setStatus("Generated scenarios failed quality gates.", "warn")
                updateButtonStates()
                return true
            elseif status == "cancelled" then
                editorGenerationJob = nil
                setStatus("Scenario generation cancelled.", "warn")
                updateButtonStates()
                return true
            elseif status == "error" then
                editorGenerationJob = nil
                appendLog("- Generator worker failed: " .. tostring(message.reason or "worker_error"))
                setStatus("Scenario generator worker failed.", "error")
                updateButtonStates()
                return true
            end
        end
    end

    if handledMessage then
        setStatus("Generating scenario candidate... Back cancels.", "info")
    elseif job.thread and type(job.thread.getError) == "function" then
        local okError, threadErr = pcall(function()
            return job.thread:getError()
        end)
        if okError and threadErr then
            appendLog("- Generator worker fallback.")
            scenarioTrace("Editor", "- new_scenario.thread_error_fallback reason=" .. tostring(threadErr))
            job.mode = "inline"
            job.thread = nil
            job.responseChannel = nil
            job.cancelChannel = nil
            setStatus("Generator worker fallback; continuing.", "warn")
            updateButtonStates()
            return true
        end
    end
    updateButtonStates()
    return true
end

local function stepScenarioGenerationJob()
    if not isGenerationActive() then
        return false
    end

    local job = editorGenerationJob
    if job.mode == "thread" then
        return pollScenarioGenerationThread(job)
    end

    if job.cancelled == true then
        editorGenerationJob = nil
        setStatus("Scenario generation cancelled.", "warn")
        updateButtonStates()
        return true
    end

    if job.attempt >= job.maxAttempts then
        editorGenerationJob = nil
        appendLog("- No certified scenario found.")
        setStatus("No generated scenario passed the gates.", "warn")
        updateButtonStates()
        return true
    end

    job.attempt = job.attempt + 1
    local profile, profileIndex = generatorProfileForAttempt(job)
    if not profile then
        editorGenerationJob = nil
        appendLog("- Generator profile list is empty.")
        setStatus("Scenario generator has no profiles.", "error")
        updateButtonStates()
        return true
    end

    local seed = (job.seedBase + (job.attempt * 104729) + (profileIndex * 4099)) % 4294967296
    appendLog(string.format("- Try %02d/%02d: %s.", job.attempt, job.maxAttempts, tostring(profile.label or profile.archetype)))
    scenarioTrace("Editor", string.format(
        "new_scenario.attempt attempt=%d seed=%d archetype=%s",
        job.attempt,
        seed,
        tostring(profile.archetype)
    ))

    local dossier = job.retroGenerator.generate({
        seed = seed,
        turnLimit = 3,
        archetype = profile.archetype,
        solverMaxNodes = SCENARIO_NEW_GENERATOR_SOLVER_MAX_NODES,
        maxAttempts = 1
    })
    local quality = job.qualityEvaluator.evaluate(dossier)
    traceGeneratedDossier(seed, dossier, quality)
    local isCertified = type(dossier) == "table" and dossier.pipelineState == "certified"
    local isQualityApproved = type(quality) == "table" and quality.status == "approved"
    local allowEditorPlaytest = profile.allowEditorPlaytest == true
    local canLoadForEditor = isCertified and (isQualityApproved or allowEditorPlaytest)

    if canLoadForEditor then
        local loaded, loadErr = loadGeneratedScenarioIntoEditor(dossier, quality)
        if loaded then
            editorGenerationJob = nil
            appendLog(string.format("- Generated %s loaded (%d units).", tostring(scenarioCode), #editorUnits))
            appendLog(string.format("- Archetype: %s.", tostring(dossier.tacticalFingerprint and dossier.tacticalFingerprint.role_signature or profile.archetype)))
            if allowEditorPlaytest and not isQualityApproved then
                appendLog("- Editor playtest profile: not release-quality approved.")
            end
            appendLog(string.format("- Proof: %s, false lines: %d.", tostring(dossier.solverProof and dossier.solverProof.status or "unknown"), #(dossier.falseLines or {})))
            traceUnitList("Editor", "editor.units_after_new_scenario", editorUnits)
            setStatus("Generated scenario loaded into editor.", "ok")
            updateButtonStates()
            return true
        end

        appendLog("- Generated candidate could not load: " .. tostring(loadErr))
        scenarioTrace("Editor", "- new_scenario.load_rejected reason=" .. tostring(loadErr))
    else
        local rejectionSummary = summarizeRejectedGeneration(dossier, quality)
        scenarioTrace("Editor", "- new_scenario.rejected reasons=" .. rejectionSummary)
    end

    if job.attempt >= job.maxAttempts then
        editorGenerationJob = nil
        appendLog("- Generated candidates rejected by gates.")
        setStatus("Generated scenarios failed quality gates.", "warn")
        updateButtonStates()
        return true
    end

    setStatus("Generating scenario candidate... Back cancels.", "info")
    updateButtonStates()
    return true
end

local function onNewScenario()
    startNewScenarioGeneration()
end

local function onSimulate()
    if not (GAME and GAME.CURRENT) then
        setStatus("Simulation unavailable: GAME context missing.", "error")
        return
    end

    local hasBlueUnit = false
    local hasRedCommandant = false
    for _, unit in ipairs(editorUnits) do
        if unit.name ~= "Rock" and tonumber(unit.player) == 1 then
            hasBlueUnit = true
        end
        if unit.name == "Commandant" and tonumber(unit.player) == 2 then
            hasRedCommandant = true
        end
    end

    if not hasBlueUnit or not hasRedCommandant then
        local messageParts = {}
        if not hasBlueUnit then
            messageParts[#messageParts + 1] = "- At least one Blue unit is required."
        end
        if not hasRedCommandant then
            messageParts[#messageParts + 1] = "- One Red Commandant is required."
        end
        local messageText = "Cannot launch simulation.\n\n" .. table.concat(messageParts, "\n")
        if ConfirmDialog and ConfirmDialog.showMessage then
            ConfirmDialog.showMessage(messageText, nil, {
                title = "Simulation Blocked",
                confirmText = "OK"
            })
        end
        setStatus("Simulation blocked: missing required units.", "warn")
        return
    end

    local snapshot, snapshotErr = buildRuntimeScenarioSnapshotFromEditor()
    if type(snapshot) ~= "table" then
        setStatus("Cannot simulate: " .. formatSnapshotBuildError(snapshotErr), "error")
        return
    end
    traceUnitList("Editor", "simulate.snapshot.boardUnits", snapshot.boardUnits or {})

    if GAME and type(GAME.resetToDefaultControllers) == "function" then
        GAME.resetToDefaultControllers()
    end

    editorScenarioAttempts = math.max(0, math.floor(tonumber(editorScenarioAttempts) or 0)) + 1

    local turnsTarget = math.max(1, math.floor(tonumber(scenarioRoundLimit) or 1))
    local scenarioId = normalizeScenarioCode(scenarioCode)
    local objectiveText = "Blue to move. Destroy the enemy Commandant within " .. tostring(turnsTarget) .. " turns."

    GAME.CURRENT.SCENARIO = {
        id = scenarioId,
        name = "Scenario " .. scenarioId,
        status = "EDITOR",
        solved = false,
        attempts = editorScenarioAttempts,
        turnsTarget = turnsTarget,
        objectiveMessage = objectiveText,
        objectiveText = objectiveText,
        objectiveType = "destroy_commandant",
        sideToMove = "Blue",
        scenarioRedPolicy = buildScenarioRedPolicyConfig(),
        sourcePath = "scenario_editor_runtime",
        snapshot = snapshot
    }
    traceScenarioPolicyConfig("Editor", "simulate.scenarioRedPolicy", GAME.CURRENT.SCENARIO.scenarioRedPolicy)
    GAME.CURRENT.SCENARIO_RESULT = nil
    GAME.CURRENT.SCENARIO_RETURN_STATE = "scenarioEditor"
    GAME.CURRENT.SCENARIO_REQUESTED_MODE = GAME.MODE.SCENARIO
    GAME.CURRENT.MODE = GAME.MODE.SCENARIO
    GAME.CURRENT.LOCAL_MATCH_VARIANT = "couch"
    GAME.CURRENT.PENDING_RESUME_SNAPSHOT = nil
    GAME.CURRENT.RESUME_RESTART_NOTICE = nil

    clearOnlineRuntime()
    setStatus("Simulation launched.", "ok")

    if stateMachineRef and stateMachineRef.changeState then
        stateMachineRef.changeState("scenarioGameplay")
    end
end

local function luaQuote(value)
    return string.format("%q", tostring(value or ""))
end

local function isIdentifierKey(value)
    return type(value) == "string" and value:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function sortedTableKeys(tbl)
    local numericKeys = {}
    local stringKeys = {}
    local otherKeys = {}
    for key in pairs(tbl or {}) do
        if type(key) == "number" then
            numericKeys[#numericKeys + 1] = key
        elseif type(key) == "string" then
            stringKeys[#stringKeys + 1] = key
        else
            otherKeys[#otherKeys + 1] = key
        end
    end
    table.sort(numericKeys)
    table.sort(stringKeys)
    table.sort(otherKeys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    local keys = {}
    for _, key in ipairs(numericKeys) do keys[#keys + 1] = key end
    for _, key in ipairs(stringKeys) do keys[#keys + 1] = key end
    for _, key in ipairs(otherKeys) do keys[#keys + 1] = key end
    return keys
end

local function serializeLuaValue(value, indent, seen)
    indent = indent or 0
    local valueType = type(value)
    if valueType == "nil" then
        return "nil"
    end
    if valueType == "boolean" or valueType == "number" then
        return tostring(value)
    end
    if valueType == "string" then
        return luaQuote(value)
    end
    if valueType ~= "table" then
        return luaQuote(value)
    end

    seen = seen or {}
    if seen[value] then
        error("cannot export recursive table", 2)
    end
    seen[value] = true

    local keys = sortedTableKeys(value)
    if #keys == 0 then
        seen[value] = nil
        return "{}"
    end

    local pad = string.rep(" ", indent)
    local childPad = string.rep(" ", indent + 4)
    local lines = {}
    for _, key in ipairs(keys) do
        local keyPrefix
        if isIdentifierKey(key) then
            keyPrefix = key .. " = "
        elseif type(key) == "number" then
            keyPrefix = "[" .. tostring(key) .. "] = "
        else
            keyPrefix = "[" .. luaQuote(key) .. "] = "
        end
        lines[#lines + 1] = childPad .. keyPrefix .. serializeLuaValue(value[key], indent + 4, seen)
    end

    seen[value] = nil
    return "{\n" .. table.concat(lines, ",\n") .. "\n" .. pad .. "}"
end

local function scenarioFileExists(path)
    if love and love.filesystem and type(love.filesystem.getInfo) == "function" then
        local ok, info = pcall(love.filesystem.getInfo, path)
        return ok and info ~= nil
    end

    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

local function generateExportScenarioCode()
    scenarioExportCounter = scenarioExportCounter + 1
    local stamp = os.date and os.date("%Y%m%d%H%M%S") or tostring(os.time and os.time() or 1)
    local suffix = scenarioExportCounter
    if love and love.timer and type(love.timer.getTime) == "function" then
        suffix = suffix + math.floor((love.timer.getTime() * 1000) % 1000)
    end

    local base = "Scenario#" .. tostring(stamp) .. "-" .. string.format("%03d", suffix)
    local candidate = base
    local attempt = 1
    while scenarioFileExists("scenarios/" .. candidate .. ".lua") do
        attempt = attempt + 1
        candidate = base .. "-" .. tostring(attempt)
    end
    return candidate
end

local function buildScenarioExportContent(exportCode, snapshot, turnsTarget, redPolicyConfig, dossierPath, solutionPath)
    local objectiveText = "Blue to move. Destroy the enemy Commandant within " .. tostring(turnsTarget) .. " turns."
    return table.concat({
        "-- Exported from Scenario Editor. Scenario-only data; no standard AI dependency.",
        "return {",
        "    id = " .. luaQuote(exportCode) .. ",",
        "    name = " .. luaQuote("Scenario " .. exportCode) .. ",",
        "    status = " .. luaQuote(SCENARIO_EXPORT_STATUS) .. ",",
        "    promotion = {",
        "        state = \"promoted\",",
        "        approved = true,",
        "        source = \"scenario_editor_manual_export\",",
        "        dossierPath = " .. luaQuote(dossierPath or "") .. ",",
        "        solutionPath = " .. luaQuote(solutionPath or ""),
        "    },",
        "    objectiveType = \"destroy_commandant\",",
        "    objectiveMessage = " .. luaQuote(objectiveText) .. ",",
        "    objectiveText = " .. luaQuote(objectiveText) .. ",",
        "    sideToMove = \"Blue\",",
        "    turnLimitRounds = " .. tostring(turnsTarget) .. ",",
        "    dossierPath = " .. luaQuote(dossierPath or "") .. ",",
        "    solutionPath = " .. luaQuote(solutionPath or "") .. ",",
        "    scenarioRedPolicy = " .. serializeLuaValue(redPolicyConfig or buildScenarioRedPolicyConfig(), 4) .. ",",
        "    startSnapshot = " .. serializeLuaValue(snapshot, 4),
        "}",
        ""
    }, "\n")
end

local function buildScenarioExportDossier(exportCode, snapshot, turnsTarget, redPolicyConfig, solutionPath)
    local sourceDossier = type(editorGeneratedDossier) == "table" and cloneValue(editorGeneratedDossier) or nil
    local sourceQuality = type(editorGeneratedQuality) == "table" and cloneValue(editorGeneratedQuality) or nil
    local proofApplies = sourceDossier ~= nil and editorBoardDirtySinceDossier ~= true

    return {
        schema = "ScenarioExportDossier",
        version = 1,
        id = exportCode,
        status = "promoted",
        promotion = {
            state = "promoted",
            approved = true,
            source = "scenario_editor_manual_export"
        },
        manualPromotion = true,
        exportedAt = os.date and os.date("!%Y-%m-%dT%H:%M:%SZ") or nil,
        solutionPath = solutionPath,
        turnLimitRounds = turnsTarget,
        proofAppliesToCurrentSnapshot = proofApplies,
        sourceDossierStale = sourceDossier ~= nil and editorBoardDirtySinceDossier == true or false,
        sourceSolutionStale = sourceDossier ~= nil and editorBoardDirtySinceDossier == true or false,
        solutionAppliesToCurrentSnapshot = proofApplies,
        dirtyReason = editorBoardDirtyReason,
        scenarioRedPolicy = cloneValue(redPolicyConfig or {}),
        currentSnapshot = cloneValue(snapshot),
        sourceQuality = sourceQuality,
        sourceDossier = sourceDossier,
        proofCertificate = sourceDossier and cloneValue(sourceDossier.proofCertificate) or nil,
        solverProof = sourceDossier and cloneValue(sourceDossier.solverProof) or nil,
        falseLines = sourceDossier and cloneValue(sourceDossier.falseLines) or nil
    }
end

local function buildScenarioExportDossierContent(exportDossier)
    return table.concat({
        "-- Scenario export dossier. Internal Scenario Mode tooling metadata.",
        "-- Playable scenario files are shipped separately from proof/promotion records.",
        "return " .. serializeLuaValue(exportDossier, 0),
        ""
    }, "\n")
end

local function buildScenarioExportSolution(exportCode, solutionPath)
    local sourceDossierRaw = type(editorGeneratedDossier) == "table" and editorGeneratedDossier or nil
    local sourceDossier = sourceDossierRaw and cloneValue(sourceDossierRaw) or nil
    local sourceSolutionRaw = sourceDossierRaw and type(sourceDossierRaw.solution) == "table" and sourceDossierRaw.solution or nil
    local actions = canonicalExportActionList(sourceSolutionRaw and sourceSolutionRaw.actions or {})
    if #actions == 0 and sourceDossierRaw and type(sourceDossierRaw.solverProof) == "table" then
        actions = canonicalExportActionList(sourceDossierRaw.solverProof.winningLine or {})
    end

    return {
        schema = "ScenarioSolution",
        version = 1,
        id = exportCode,
        solutionPath = solutionPath,
        exportedAt = os.date and os.date("!%Y-%m-%dT%H:%M:%SZ") or nil,
        generatedWithScenario = sourceDossier ~= nil,
        sourceDossierId = sourceDossier and sourceDossier.id or nil,
        sourceSeed = sourceDossier and sourceDossier.seed or nil,
        sourceContractPattern = sourceDossier and sourceDossier.contractPattern or nil,
        sourceSolutionStale = sourceDossier ~= nil and editorBoardDirtySinceDossier == true or false,
        solutionAppliesToCurrentSnapshot = sourceDossier ~= nil and editorBoardDirtySinceDossier ~= true,
        dirtyReason = editorBoardDirtyReason,
        note = "Solution is generated with the scenario candidate and is not recomputed from manual editor edits.",
        actions = actions,
        solution = { actions = cloneValue(actions) },
        falseLines = sourceDossier and cloneValue(sourceDossier.falseLines) or {},
        proofCertificate = sourceDossier and cloneValue(sourceDossier.proofCertificate) or nil,
        solverProof = sourceDossier and cloneValue(sourceDossier.solverProof) or nil
    }
end

local function buildScenarioExportSolutionContent(exportSolution)
    return table.concat({
        "-- Scenario solution sidecar. Generated from the original candidate dossier.",
        "-- Manual editor edits are exported in the playable scenario snapshot, not recomputed here.",
        "return " .. serializeLuaValue(exportSolution, 0),
        ""
    }, "\n")
end

local function scenarioExportDirectory(path)
    return tostring(path or ""):match("^(.*)/[^/]+$") or ""
end

local function writeScenarioExportFile(path, content)
    if love and love.filesystem and type(love.filesystem.write) == "function" then
        if type(love.filesystem.createDirectory) == "function" then
            local directory = scenarioExportDirectory(path)
            if directory ~= "" then
                pcall(love.filesystem.createDirectory, directory)
            end
        end
        local ok, result, err = pcall(love.filesystem.write, path, content)
        if ok and result then
            return true, path
        end
        return false, tostring(err or result or "write_failed")
    end

    local file, err = io.open(path, "w")
    if not file then
        return false, tostring(err or "write_failed")
    end
    file:write(content)
    file:close()
    return true, path
end

local function onExport()
    local redCmdCount = 0
    local hasBlueUnit = false
    for _, unit in ipairs(editorUnits) do
        if unit.name ~= "Rock" and tonumber(unit.player) == 1 then
            hasBlueUnit = true
        end
        if unit.name == "Commandant" and tonumber(unit.player) == 2 then
            redCmdCount = redCmdCount + 1
        end
    end

    if not hasBlueUnit or redCmdCount ~= 1 then
        appendLog(string.format("- Export blocked (blue unit: %s, red commandants: %d).", tostring(hasBlueUnit), redCmdCount))
        setStatus("Export blocked: need Blue unit and exactly one Red Commandant.", "error")
        return
    end

    local snapshot, snapshotErr = buildRuntimeScenarioSnapshotFromEditor()
    if type(snapshot) ~= "table" then
        setStatus("Cannot export: " .. formatSnapshotBuildError(snapshotErr), "error")
        return
    end

    local exportCode = generateExportScenarioCode()
    local turnsTarget = math.max(1, math.floor(tonumber(scenarioRoundLimit) or 1))
    local path = "scenarios/" .. exportCode .. ".lua"
    local dossierPath = SCENARIO_DOSSIER_DIR .. "/" .. exportCode .. ".dossier.lua"
    local solutionPath = SCENARIO_SOLUTION_DIR .. "/" .. exportCode .. ".solution.lua"
    local redPolicyConfig = buildScenarioRedPolicyConfig()
    local exportSolution = buildScenarioExportSolution(exportCode, solutionPath)
    local solutionContent = buildScenarioExportSolutionContent(exportSolution)
    local solutionOk, solutionWriteResult = writeScenarioExportFile(solutionPath, solutionContent)
    if not solutionOk then
        appendLog("- Export solution failed: " .. tostring(solutionWriteResult))
        setStatus("Export failed: solution write failed.", "error")
        return
    end

    local exportDossier = buildScenarioExportDossier(exportCode, snapshot, turnsTarget, redPolicyConfig, solutionPath)
    local dossierContent = buildScenarioExportDossierContent(exportDossier)
    local dossierOk, dossierWriteResult = writeScenarioExportFile(dossierPath, dossierContent)
    if not dossierOk then
        appendLog("- Export dossier failed: " .. tostring(dossierWriteResult))
        setStatus("Export failed: dossier write failed.", "error")
        return
    end

    local content = buildScenarioExportContent(exportCode, snapshot, turnsTarget, redPolicyConfig, dossierPath, solutionPath)
    local ok, writeResult = writeScenarioExportFile(path, content)
    if not ok then
        appendLog("- Export failed: " .. tostring(writeResult))
        setStatus("Export failed.", "error")
        return
    end

    scenarioCode = exportCode
    appendLog("- Exported " .. tostring(writeResult))
    appendLog("- Dossier " .. tostring(dossierWriteResult))
    appendLog("- Solution " .. tostring(solutionWriteResult))
    setStatus("Scenario exported and promoted: " .. exportCode, "ok")
end

local function onRoundMinus()
    local previousLimit = scenarioRoundLimit
    scenarioRoundLimit = math.max(1, scenarioRoundLimit - 1)
    if scenarioRoundLimit ~= previousLimit then
        markEditorBoardDirty("round_limit_changed")
    end
    setStatus("Round limit updated.", "info")
end

local function onRoundPlus()
    local previousLimit = scenarioRoundLimit
    scenarioRoundLimit = math.min(99, scenarioRoundLimit + 1)
    if scenarioRoundLimit ~= previousLimit then
        markEditorBoardDirty("round_limit_changed")
    end
    setStatus("Round limit updated.", "info")
end

local function cycleIndex(current, maxValue)
    if maxValue <= 0 then
        return 1
    end
    local nextValue = (current or 1) + 1
    if nextValue > maxValue then
        nextValue = 1
    end
    return nextValue
end

local function onTagCycle()
    scenarioTagIndex = cycleIndex(scenarioTagIndex, #scenarioTagValues)
    setStatus("Scenario tag updated.", "info")
end

local function onComplexityCycle()
    scenarioComplexityIndex = cycleIndex(scenarioComplexityIndex, #scenarioComplexityValues)
    setStatus("Scenario complexity updated.", "info")
end

local function onChangeFaction()
    local unit = getSelectedUnit()
    if not unit then
        return
    end
    if unit.player == 1 then
        unit.player = 2
    elseif unit.player == 2 then
        unit.player = 1
    else
        unit.player = 1
    end
    markEditorBoardDirty("unit_faction_changed")
    setStatus("Unit faction changed.", "ok")
end

local function onCycleUnit()
    local unit = getSelectedUnit()
    if not unit then
        if findUnitIndexAt(selectedCell.row, selectedCell.col) then
            setStatus("Cell already occupied.", "warn")
            return
        end
        local defaultName = UNIT_CYCLE[1] or "Wingstalker"
        editorUnits[#editorUnits + 1] = {
            name = defaultName,
            player = 1,
            row = selectedCell.row,
            col = selectedCell.col,
            hp = getUnitBaseHp(defaultName),
            acted = false
        }
        selectedUnitIndex = #editorUnits
        markEditorBoardDirty("unit_added")
        setStatus("Unit added.", "ok")
        return
    end
    if unit.name == "Commandant" and tonumber(unit.player) == 2 then
        setStatus("Red Commandant cannot be cycled.", "warn")
        return
    end
    local currentIndex = 1
    for i, name in ipairs(UNIT_CYCLE) do
        if name == unit.name then
            currentIndex = i
            break
        end
    end
    local nextIndex = cycleIndex(currentIndex, #UNIT_CYCLE)
    unit.name = UNIT_CYCLE[nextIndex]
    if unit.name ~= "Rock" and unit.player ~= 1 and unit.player ~= 2 then
        unit.player = 1
    end
    unit.hp = getUnitBaseHp(unit.name)
    markEditorBoardDirty("unit_type_changed")
    setStatus("Unit type cycled.", "ok")
end

local function onAddRock()
    if findUnitIndexAt(selectedCell.row, selectedCell.col) then
        setStatus("Cell already occupied.", "warn")
        return
    end
    editorUnits[#editorUnits + 1] = {
        name = "Rock",
        player = 0,
        row = selectedCell.row,
        col = selectedCell.col,
        hp = getUnitBaseHp("Rock")
    }
    selectedUnitIndex = #editorUnits
    markEditorBoardDirty("rock_added")
    setStatus("Rock added.", "ok")
end

local function onAddRedCommandant()
    for index = #editorUnits, 1, -1 do
        local unit = editorUnits[index]
        if unit.name == "Commandant" and unit.player == 2 then
            table.remove(editorUnits, index)
            if selectedUnitIndex and selectedUnitIndex >= index then
                selectedUnitIndex = selectedUnitIndex - 1
            end
        end
    end

    local existing = findUnitIndexAt(selectedCell.row, selectedCell.col)
    if existing then
        local unit = editorUnits[existing]
        unit.name = "Commandant"
        unit.player = 2
        unit.hp = getUnitBaseHp("Commandant")
        selectedUnitIndex = existing
    else
        editorUnits[#editorUnits + 1] = {
            name = "Commandant",
            player = 2,
            row = selectedCell.row,
            col = selectedCell.col,
            hp = getUnitBaseHp("Commandant")
        }
        selectedUnitIndex = #editorUnits
    end

    markEditorBoardDirty("red_commandant_placed")
    setStatus("Red commandant placed.", "ok")
end

local function onHpDelta(delta)
    local unit = getSelectedUnit()
    if not unit then
        return
    end
    local previousHp = unit.hp
    unit.hp = math.max(1, math.min(99, math.floor((tonumber(unit.hp) or 1) + delta)))
    if unit.hp ~= previousHp then
        markEditorBoardDirty("unit_hp_changed")
    end
    setStatus("Unit HP updated.", "ok")
end

local function onToggleActed()
    local unit = getSelectedUnit()
    if not unit then
        return
    end
    unit.acted = not (unit.acted == true)
    markEditorBoardDirty("unit_acted_flag_changed")
    setStatus("Acted flag toggled.", "ok")
end

local function onRemoveUnit()
    local _, index = getSelectedUnit()
    if not index then
        return
    end
    table.remove(editorUnits, index)
    selectedUnitIndex = nil
    markEditorBoardDirty("unit_removed")
    setStatus("Unit removed.", "ok")
end

local function triggerSelectedButton(button)
    if not button or button.enabled == false then
        return
    end

    playClickSound()

    if button == uiButtons.back then
        onBack()
    elseif button == uiButtons.newScenario then
        onNewScenario()
    elseif button == uiButtons.simulate then
        onSimulate()
    elseif button == uiButtons.export then
        onExport()
    elseif button == uiButtons.roundMinus then
        onRoundMinus()
    elseif button == uiButtons.roundPlus then
        onRoundPlus()
    elseif button == uiButtons.tagButton then
        onTagCycle()
    elseif button == uiButtons.complexityButton then
        onComplexityCycle()
    elseif button == uiButtons.changeFaction then
        onChangeFaction()
    elseif button == uiButtons.cycleUnit then
        onCycleUnit()
    elseif button == uiButtons.addRock then
        onAddRock()
    elseif button == uiButtons.addRedCmd then
        onAddRedCommandant()
    elseif button == uiButtons.hpMinus then
        onHpDelta(-1)
    elseif button == uiButtons.hpPlus then
        onHpDelta(1)
    elseif button == uiButtons.toggleActed then
        onToggleActed()
    elseif button == uiButtons.removeUnit then
        onRemoveUnit()
    end

    updateButtonStates()
end

local function toLocalCoordinates(x, y)
    return
        (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE,
        (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
end

local function isMouseOverButton(button, x, y)
    return button
        and x >= button.x and x <= button.x + button.width
        and y >= button.y and y <= button.y + button.height
end

local function boardCellAt(x, y)
    local layout = buildLayout()
    local board = layout.board
    if x < board.x or y < board.y then
        return nil, nil
    end

    local maxX = board.x + board.pixelSize
    local maxY = board.y + board.pixelSize
    if x >= maxX or y >= maxY then
        return nil, nil
    end

    local col = math.floor((x - board.x) / board.cellSize) + 1
    local row = math.floor((y - board.y) / board.cellSize) + 1
    if row < 1 or row > 8 or col < 1 or col > 8 then
        return nil, nil
    end
    return row, col
end

local function handleBoardClick(row, col)
    selectCell(row, col)
    local clickedUnitIndex = findUnitIndexAt(row, col)
    if clickedUnitIndex then
        selectedUnitIndex = clickedUnitIndex
        local unit = editorUnits[clickedUnitIndex]
        setStatus(string.format("Selected %s (%s%d).", unit.name, BOARD_LETTERS[col], row), "info")
        return
    end

    selectedUnitIndex = nil
    setStatus(string.format("Selected empty cell %s%d. Use Add Unit/Add Rock/Add Red Cmd.", BOARD_LETTERS[col], row), "info")
end

local function resolveScenarioHeader()
    local scenarioState = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
    if type(scenarioState) == "table" then
        local code = tostring(scenarioState.id or scenarioCode)
        local turnsTarget = tonumber(scenarioState.turnsTarget)
        if turnsTarget and turnsTarget > 0 then
            scenarioRoundLimit = math.floor(turnsTarget)
        end
        scenarioCode = code ~= "" and code or scenarioCode
    end
end

function scenarioEditor.enter(stateMachine)
    stateMachineRef = stateMachine
    resolveScenarioHeader()
    scenarioCode = normalizeScenarioCode(scenarioCode)

    local defaultPresetKey = buildDefaultEditorPresetKey()
    if not editorInitialized or editorDefaultPresetKey ~= defaultPresetKey then
        scenarioCode = DEFAULT_EDITOR_SCENARIO_CODE
        scenarioRoundLimit = DEFAULT_EDITOR_ROUND_LIMIT
        defaultPresetKey = buildDefaultEditorPresetKey()
        editorUnits = cloneValue(buildDefaultEditorUnits())
        editorLogLines = {
            "- Simulation started from current editor scenario.",
            "- Use Back in gameplay to return to editor."
        }
        editorScenarioAttempts = 0
        selectedUnitIndex = nil
        selectCell(1, 1)
        setStatus("Editor ready. Click a unit or a cell.", "info")
        editorInitialized = true
        editorDefaultPresetKey = defaultPresetKey
        editorBoardDirtySinceDossier = false
        editorBoardDirtyReason = nil
    else
        if type(editorLogLines) ~= "table" then
            editorLogLines = {}
        end
        if selectedUnitIndex and editorUnits[selectedUnitIndex] == nil then
            selectedUnitIndex = nil
        end
        selectCell(selectedCell.row or 1, selectedCell.col or 1)
    end

    initializeButtons()
    selectedButtonIndex = 1
    boardFocus = true
    lastHoveredTarget = nil

    updateButtonStates()
end

function scenarioEditor.exit()
    if isGenerationActive() and editorGenerationJob.mode == "thread" and editorGenerationJob.cancelChannel then
        pcall(function()
            editorGenerationJob.cancelChannel:push(true)
        end)
    end
    editorGenerationJob = nil
    stateMachineRef = nil
end

function scenarioEditor.update(dt)
    if ConfirmDialog and ConfirmDialog.isActive and ConfirmDialog.isActive() then
        ConfirmDialog.update(dt)
        return
    end
    stepScenarioGenerationJob()
    updateButtonStates()
end

function scenarioEditor.resize(w, h)
    initializeButtons()
    updateButtonStates()
end

function scenarioEditor.draw()
    local layout = buildLayout()
    local board = layout.board

    love.graphics.push()
    love.graphics.translate(SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY)
    love.graphics.scale(SETTINGS.DISPLAY.SCALE)

    love.graphics.setColor(uiTheme.COLORS.background)
    love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)

    uiTheme.drawTechPanel(layout.leftPanel.x, layout.leftPanel.y, layout.leftPanel.width, layout.leftPanel.height)
    uiTheme.drawTechPanel(layout.rightPanel.x, layout.rightPanel.y, layout.rightPanel.width, layout.rightPanel.height)

    love.graphics.setColor(0.90, 0.88, 0.82, 1)
    love.graphics.printf("Scenario Board", layout.leftPanel.x + 14, layout.leftPanel.y + 12, layout.leftPanel.width - 28, "left")

    for col = 1, 8 do
        local label = BOARD_LETTERS[col]
        local x = board.x + (col - 1) * board.cellSize
        love.graphics.setColor(0.80, 0.82, 0.84, 0.95)
        love.graphics.printf(label, x, board.y - 20, board.cellSize, "center")
    end
    for col = 1, 8 do
        local label = BOARD_LETTERS[col]
        local x = board.x + (col - 1) * board.cellSize
        love.graphics.setColor(0.80, 0.82, 0.84, 0.95)
        love.graphics.printf(label, x, board.y + board.pixelSize + 4, board.cellSize, "center")
    end
    for row = 1, 8 do
        local y = board.y + (row - 1) * board.cellSize
        love.graphics.setColor(0.80, 0.82, 0.84, 0.95)
        love.graphics.printf(tostring(row), board.x - 22, y + 22, 18, "center")
    end
    for row = 1, 8 do
        local y = board.y + (row - 1) * board.cellSize
        love.graphics.setColor(0.80, 0.82, 0.84, 0.95)
        love.graphics.printf(tostring(row), board.x + board.pixelSize + 4, y + 22, 18, "center")
    end

    for row = 1, 8 do
        for col = 1, 8 do
            local x = board.x + (col - 1) * board.cellSize
            local y = board.y + (row - 1) * board.cellSize
            local isLight = ((row + col) % 2) == 0
            if isLight then
                love.graphics.setColor(0.58, 0.60, 0.36, 0.95)
            else
                love.graphics.setColor(0.50, 0.54, 0.31, 0.95)
            end
            love.graphics.rectangle("fill", x, y, board.cellSize, board.cellSize)
            love.graphics.setColor(1, 1, 1, 0.06)
            love.graphics.rectangle("line", x, y, board.cellSize, board.cellSize)
        end
    end

    local selectedX = board.x + (selectedCell.col - 1) * board.cellSize
    local selectedY = board.y + (selectedCell.row - 1) * board.cellSize
    love.graphics.setColor(0.96, 0.86, 0.22, boardFocus and 0.95 or 0.65)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", selectedX + 1, selectedY + 1, board.cellSize - 2, board.cellSize - 2)
    love.graphics.setLineWidth(1)

    for index, unit in ipairs(editorUnits) do
        local cellX = board.x + (unit.col - 1) * board.cellSize
        local cellY = board.y + (unit.row - 1) * board.cellSize
        local sprite = getUnitSprite(unit)
        if sprite then
            local available = board.cellSize - 8
            local scale = math.min(available / sprite:getWidth(), available / sprite:getHeight())
            local drawW = sprite:getWidth() * scale
            local drawH = sprite:getHeight() * scale
            local drawX = cellX + (board.cellSize - drawW) / 2
            local drawY = cellY + (board.cellSize - drawH) / 2 + 2
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(sprite, drawX, drawY, 0, scale, scale)
        else
            local factionColor = uiTheme.getFactionColor(unit.player)
            love.graphics.setColor(factionColor)
            love.graphics.circle("fill", cellX + board.cellSize / 2, cellY + board.cellSize / 2, board.cellSize * 0.28)
        end

        if selectedUnitIndex == index then
            love.graphics.setColor(1, 0.92, 0.35, 0.9)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", cellX + 4, cellY + 4, board.cellSize - 8, board.cellSize - 8, 6, 6)
            love.graphics.setLineWidth(1)
        end

        local badgeW, badgeH = 18, 14
        local badgeX = cellX + board.cellSize - badgeW - 4
        local badgeY = cellY + 4
        love.graphics.setColor(0.12, 0.12, 0.12, 0.95)
        love.graphics.rectangle("fill", badgeX, badgeY, badgeW, badgeH, 3, 3)
        love.graphics.setColor(0.95, 0.95, 0.95, 1)
        love.graphics.printf(tostring(math.max(0, math.floor(tonumber(unit.hp) or 0))), badgeX, badgeY + 1, badgeW, "center")

        if unit.acted then
            local actedW, actedH = 12, 12
            local actedX = cellX + 4
            local actedY = cellY + board.cellSize - actedH - 4
            love.graphics.setColor(0.96, 0.78, 0.18, 0.95)
            love.graphics.rectangle("fill", actedX, actedY, actedW, actedH, 2, 2)
            love.graphics.setColor(0.12, 0.12, 0.12, 0.95)
            love.graphics.printf("A", actedX, actedY - 1, actedW, "center")
        end
    end

    uiTheme.drawTechPanel(layout.sectionScenario.x, layout.sectionScenario.y, layout.sectionScenario.width, layout.sectionScenario.height)
    uiTheme.drawTechPanel(layout.sectionSelected.x, layout.sectionSelected.y, layout.sectionSelected.width, layout.sectionSelected.height)
    uiTheme.drawTechPanel(layout.sectionConfig.x, layout.sectionConfig.y, layout.sectionConfig.width, layout.sectionConfig.height)
    uiTheme.drawTechPanel(layout.sectionLog.x, layout.sectionLog.y, layout.sectionLog.width, layout.sectionLog.height)

    love.graphics.setColor(0.92, 0.90, 0.86, 1)
    love.graphics.printf("Scenario", layout.sectionScenario.x + 10, layout.sectionScenario.y + 8, layout.sectionScenario.width - 20, "left")
    love.graphics.setColor(0.82, 0.84, 0.88, 1)
    love.graphics.printf("Code: " .. tostring(scenarioCode), layout.sectionScenario.x + 12, layout.sectionScenario.y + 30, layout.sectionScenario.width - 24, "left")
    love.graphics.printf("Round Limit: " .. tostring(scenarioRoundLimit), layout.sectionScenario.x + 12, layout.sectionScenario.y + 52, layout.sectionScenario.width - 24, "left")

    love.graphics.setColor(0.92, 0.90, 0.86, 1)
    love.graphics.printf("Selected Unit", layout.sectionSelected.x + 10, layout.sectionSelected.y + 8, layout.sectionSelected.width - 20, "left")

    local selectedUnit = getSelectedUnit()
    local selectedTextX = layout.sectionSelected.x + 12
    local selectedTextY = layout.sectionSelected.y + 30
    local selectedTextW = layout.sectionSelected.width - 24
    local previewSize = math.min(84, layout.sectionSelected.height - 40)
    local previewX = layout.sectionSelected.x + layout.sectionSelected.width - previewSize - 12
    local previewY = layout.sectionSelected.y + 26

    if selectedUnit then
        local sprite = getUnitSprite(selectedUnit)
        love.graphics.setColor(0.10, 0.11, 0.12, 0.92)
        love.graphics.rectangle("fill", previewX, previewY, previewSize, previewSize, 6, 6)
        love.graphics.setColor(0.48, 0.44, 0.38, 0.95)
        love.graphics.rectangle("line", previewX, previewY, previewSize, previewSize, 6, 6)

        if sprite then
            local iconPadding = 6
            local iconMax = previewSize - (iconPadding * 2)
            local iconScale = math.min(iconMax / sprite:getWidth(), iconMax / sprite:getHeight())
            local iconW = sprite:getWidth() * iconScale
            local iconH = sprite:getHeight() * iconScale
            local iconX = previewX + (previewSize - iconW) / 2
            local iconY = previewY + (previewSize - iconH) / 2
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(sprite, iconX, iconY, 0, iconScale, iconScale)
        else
            local fallbackColor = uiTheme.getFactionColor(selectedUnit.player)
            love.graphics.setColor(fallbackColor)
            love.graphics.circle("fill", previewX + (previewSize / 2), previewY + (previewSize / 2), previewSize * 0.26)
        end

        local playerLabel = selectedUnit.player == 1 and "Blue" or (selectedUnit.player == 2 and "Red" or "Neutral")
        local selectedInfo = string.format(
            "%s (%s)\nCell: %s%d\nHP: %d",
            tostring(selectedUnit.name),
            playerLabel,
            BOARD_LETTERS[selectedUnit.col] or "?",
            tonumber(selectedUnit.row) or 0,
            math.max(0, math.floor(tonumber(selectedUnit.hp) or 0))
        )
        love.graphics.setColor(0.80, 0.82, 0.86, 1)
        love.graphics.printf(selectedInfo, selectedTextX, selectedTextY, math.max(80, previewX - selectedTextX - 10), "left")
    else
        love.graphics.setColor(0.80, 0.82, 0.86, 1)
        love.graphics.printf("No unit selected.", selectedTextX, layout.sectionSelected.y + 44, selectedTextW, "left")
    end

    love.graphics.setColor(0.92, 0.90, 0.86, 1)
    love.graphics.printf("Units Config", layout.sectionConfig.x + 10, layout.sectionConfig.y + 8, layout.sectionConfig.width - 20, "left")

    love.graphics.setColor(0.92, 0.90, 0.86, 1)
    love.graphics.printf("Simulation Log", layout.sectionLog.x + 10, layout.sectionLog.y + 8, layout.sectionLog.width - 20, "left")
    love.graphics.setColor(0.14, 0.20, 0.30, 0.85)
    love.graphics.rectangle("fill", layout.sectionLog.x + 8, layout.sectionLog.y + 28, layout.sectionLog.width - 16, layout.sectionLog.height - 36, 6, 6)
    love.graphics.setColor(0.76, 0.86, 0.94, 0.98)
    local logY = layout.sectionLog.y + 34
    for _, line in ipairs(editorLogLines) do
        love.graphics.printf(line, layout.sectionLog.x + 14, logY, layout.sectionLog.width - 28, "left")
        logY = logY + 16
    end

    for _, button in ipairs(buttonOrder) do
        uiTheme.drawButton(button)
    end

    if ConfirmDialog and ConfirmDialog.draw then
        ConfirmDialog.draw()
    end

    love.graphics.pop()
end

function scenarioEditor.mousemoved(x, y, dx, dy, istouch)
    if ConfirmDialog and ConfirmDialog.isActive and ConfirmDialog.isActive() then
        ConfirmDialog.mousemoved(x, y)
        return
    end

    local tx, ty = toLocalCoordinates(x, y)
    local hoveredTarget = nil

    for index, button in ipairs(buttonOrder) do
        if button.enabled ~= false and isMouseOverButton(button, tx, ty) then
            selectedButtonIndex = index
            boardFocus = false
            hoveredTarget = "button:" .. tostring(index)
            break
        end
    end

    if not hoveredTarget then
        local row, col = boardCellAt(tx, ty)
        if row and col then
            hoveredTarget = "board:" .. tostring(row) .. ":" .. tostring(col)
        end
    end

    if hoveredTarget and hoveredTarget ~= lastHoveredTarget and hoveredTarget:sub(1, 7) == "button:" then
        playHoverSound()
    end
    lastHoveredTarget = hoveredTarget

    updateButtonStates()
end

function scenarioEditor.mousepressed(x, y, button, istouch, presses)
    if button ~= 1 then
        return
    end

    if ConfirmDialog and ConfirmDialog.isActive and ConfirmDialog.isActive() then
        return ConfirmDialog.mousepressed(x, y, button)
    end

    local tx, ty = toLocalCoordinates(x, y)
    for index, candidate in ipairs(buttonOrder) do
        if candidate.enabled ~= false and isMouseOverButton(candidate, tx, ty) then
            selectedButtonIndex = index
            boardFocus = false
            triggerSelectedButton(candidate)
            return
        end
    end

    if isGenerationActive() then
        return
    end

    local row, col = boardCellAt(tx, ty)
    if row and col then
        boardFocus = true
        local clickedUnitIndex = findUnitIndexAt(row, col)
        handleBoardClick(row, col)
        if clickedUnitIndex then
            playClickSound()
        end
        updateButtonStates()
    end
end

function scenarioEditor.mousereleased(x, y, button, istouch, presses)
    if ConfirmDialog and ConfirmDialog.isActive and ConfirmDialog.isActive() then
        return ConfirmDialog.mousereleased(x, y, button)
    end
end

function scenarioEditor.keypressed(key, scancode, isrepeat)
    if ConfirmDialog and ConfirmDialog.isActive and ConfirmDialog.isActive() then
        return ConfirmDialog.keypressed(key)
    end

    if key == "escape" then
        onBack()
        return true
    end

    if isGenerationActive() then
        boardFocus = false
        selectedButtonIndex = 1
        updateButtonStates()
        if key == "return" or key == "space" then
            triggerSelectedButton(uiButtons.back)
        end
        return true
    end

    if key == "tab" then
        boardFocus = not boardFocus
        if not boardFocus then
            ensureValidButtonSelection()
        end
        updateButtonStates()
        playHoverSound()
        return true
    end

    if boardFocus then
        if key == "up" or key == "w" then
            selectCell(selectedCell.row - 1, selectedCell.col)
            selectedUnitIndex = findUnitIndexAt(selectedCell.row, selectedCell.col)
            updateButtonStates()
            playHoverSound()
            return true
        elseif key == "down" or key == "s" then
            selectCell(selectedCell.row + 1, selectedCell.col)
            selectedUnitIndex = findUnitIndexAt(selectedCell.row, selectedCell.col)
            updateButtonStates()
            playHoverSound()
            return true
        elseif key == "left" or key == "a" then
            selectCell(selectedCell.row, selectedCell.col - 1)
            selectedUnitIndex = findUnitIndexAt(selectedCell.row, selectedCell.col)
            updateButtonStates()
            playHoverSound()
            return true
        elseif key == "right" or key == "d" then
            selectCell(selectedCell.row, selectedCell.col + 1)
            selectedUnitIndex = findUnitIndexAt(selectedCell.row, selectedCell.col)
            updateButtonStates()
            playHoverSound()
            return true
        elseif key == "return" or key == "space" then
            handleBoardClick(selectedCell.row, selectedCell.col)
            updateButtonStates()
            playClickSound()
            return true
        end
        return false
    end

    if key == "left" or key == "up" or key == "a" or key == "w" then
        selectedButtonIndex = selectEnabledButton(selectedButtonIndex - 1, -1) or selectedButtonIndex
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "right" or key == "down" or key == "d" or key == "s" then
        selectedButtonIndex = selectEnabledButton(selectedButtonIndex + 1, 1) or selectedButtonIndex
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "return" or key == "space" then
        triggerSelectedButton(buttonOrder[selectedButtonIndex])
        return true
    end

    return false
end

function scenarioEditor.gamepadpressed(joystick, button)
    if ConfirmDialog and ConfirmDialog.isActive and ConfirmDialog.isActive() then
        return ConfirmDialog.gamepadpressed(joystick, button)
    end

    if button == "a" then
        return scenarioEditor.keypressed("return", "return", false)
    end
    if button == "b" or button == "back" then
        return scenarioEditor.keypressed("escape", "escape", false)
    end
    if button == "dpup" then
        return scenarioEditor.keypressed("up", "up", false)
    end
    if button == "dpdown" then
        return scenarioEditor.keypressed("down", "down", false)
    end
    if button == "dpleft" or button == "leftshoulder" then
        return scenarioEditor.keypressed("left", "left", false)
    end
    if button == "dpright" or button == "rightshoulder" then
        return scenarioEditor.keypressed("right", "right", false)
    end
    return false
end

return scenarioEditor
