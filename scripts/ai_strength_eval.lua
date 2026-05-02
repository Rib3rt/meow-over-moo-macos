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
    SETTINGS.PERF = SETTINGS.PERF or {}
    SETTINGS.PERF.DEBUG_CONSOLE_LOG_ENABLED = false
    SETTINGS.PERF.LOG_LEVEL = "error"
    SETTINGS.PERF.LOG_CATEGORIES = SETTINGS.PERF.LOG_CATEGORIES or {}

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
local TOURNAMENT_RULES = (aiConfig.AI_PARAMS or {}).TOURNAMENT_AI or {}
local EARLY_TURN_MAX_BY_REFERENCE = TOURNAMENT_RULES.EARLY_PHASE_TURN_MAX_BY_REFERENCE or {}
local DEFAULT_EARLY_TURN_MAX = TOURNAMENT_RULES.EARLY_PHASE_TURN_MAX or 10

local GRID_SIZE = GAME.CONSTANTS.GRID_SIZE
local ACTIONS_PER_TURN = TURN_RULES.ACTIONS_PER_TURN or GAME.CONSTANTS.MAX_ACTIONS_PER_TURN or 2
local DRAW_START_TURN = DRAW_RULES.START_TURN or 10
local DRAW_LIMIT = DRAW_RULES.NO_INTERACTION_LIMIT or GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE or 10
local RANGED_UNIT_NAMES = {
    Artillery = true,
    Cloudstriker = true
}
local DEFAULT_RANDOM_PERSONALITY_POOL = {
    "marge",
    "homer",
    "lisa",
    "maggie",
    "burt",
    "burns"
}

local function normalizeReferenceName(ref)
    if ref == nil then
        return nil
    end
    local text = tostring(ref):lower()
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return nil
    end
    if text == "bart" then
        return "burt"
    end
    return text
end

local function parseReferencePool(value)
    if value == nil or tostring(value) == "" then
        local copy = {}
        for index, reference in ipairs(DEFAULT_RANDOM_PERSONALITY_POOL) do
            copy[index] = reference
        end
        return copy
    end

    local seen = {}
    local pool = {}
    for part in tostring(value):gmatch("[^,%s]+") do
        local reference = normalizeReferenceName(part)
        if reference and not seen[reference] then
            seen[reference] = true
            pool[#pool + 1] = reference
        end
    end
    if #pool == 0 then
        return parseReferencePool(nil)
    end
    return pool
end

local function referencePoolLabel(pool)
    return table.concat(pool or DEFAULT_RANDOM_PERSONALITY_POOL, ", ")
end

local function parseMaxRounds(value, fallback)
    if value == nil then
        return fallback
    end
    local text = tostring(value):lower()
    if text == "0" or text == "none" or text == "unlimited" or text == "off" or text == "false" then
        return nil
    end
    local parsed = tonumber(value)
    if parsed and parsed > 0 then
        return math.floor(parsed)
    end
    return fallback
end

local function parseArgs(argv)
    local opts = {
        matches = 20,
        maxRounds = nil,
        seed = 1337,
        reportPath = "/tmp/meowovermoo_ai_eval_report.md",
        verbose = false,
        p1Ref = "base",
        p2Ref = "base",
        randomPersonalities = false,
        personalityPool = parseReferencePool(nil),
        drawDiagnostics = false
    }

    local i = 1
    while i <= #argv do
        local argi = argv[i]
        if argi == "--matches" and argv[i + 1] then
            opts.matches = math.max(1, tonumber(argv[i + 1]) or opts.matches)
            i = i + 2
        elseif argi == "--max-rounds" and argv[i + 1] then
            opts.maxRounds = parseMaxRounds(argv[i + 1], opts.maxRounds)
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
        elseif argi == "--draw-diagnostics" then
            opts.drawDiagnostics = true
            i = i + 1
        elseif argi == "--no-draw-diagnostics" then
            opts.drawDiagnostics = false
            i = i + 1
        elseif argi == "--p1-ref" and argv[i + 1] then
            opts.p1Ref = tostring(argv[i + 1])
            i = i + 2
        elseif argi == "--p2-ref" and argv[i + 1] then
            opts.p2Ref = tostring(argv[i + 1])
            i = i + 2
        elseif argi == "--random-personalities" then
            opts.randomPersonalities = true
            i = i + 1
        elseif argi == "--fixed-personalities" then
            opts.randomPersonalities = false
            i = i + 1
        elseif argi == "--personality-pool" and argv[i + 1] then
            opts.personalityPool = parseReferencePool(argv[i + 1])
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

local function mergeCounts(target, source)
    if not (target and source) then
        return
    end
    for key, count in pairs(source or {}) do
        incrementCount(target, key, count)
    end
end

local function formatPercent(part, total)
    if not total or total <= 0 then
        return "0.00%"
    end
    return string.format("%.2f%%", (part / total) * 100)
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

local refreshDerivedState

local function findUnitAt(state, row, col)
    for _, unit in ipairs(state.units or {}) do
        if unit.row == row and unit.col == col then
            return unit
        end
    end
    return nil
end

local function manhattan(a, b)
    if not (a and b and a.row and a.col and b.row and b.col) then
        return nil
    end
    return math.abs(a.row - b.row) + math.abs(a.col - b.col)
end

local function isLivingFactionUnit(unit, includeCommandant)
    if not unit or not unit.player or unit.player <= 0 or unit.name == "Rock" then
        return false
    end
    if includeCommandant ~= true and unit.name == "Commandant" then
        return false
    end
    return (unit.currentHp or unit.startingHp or 0) > 0
end

local function unitHp(unit)
    return unit and (unit.currentHp or unit.startingHp or 0) or 0
end

local function isRangedUnit(unit)
    if not unit then
        return false
    end
    if RANGED_UNIT_NAMES[unit.name] == true then
        return true
    end
    return (unit.atkRange or unit.attackRange or 1) > 1
end

local function calculateDamage(attacker, target)
    if not (attacker and target) then
        return 0
    end
    local ok, value = pcall(function()
        return unitsInfo:calculateAttackDamage(attacker, target)
    end)
    if ok and tonumber(value) then
        return math.max(0, tonumber(value) or 0)
    end
    return math.max(0, attacker.atkDamage or 0)
end

local function normalizedReference(ref)
    return normalizeReferenceName(ref) or "base"
end

local function deterministicReferenceForMatch(opts, matchIndex, player)
    local pool = opts.personalityPool or DEFAULT_RANDOM_PERSONALITY_POOL
    if #pool <= 0 then
        pool = DEFAULT_RANDOM_PERSONALITY_POOL
    end
    local seed = math.abs(math.floor(tonumber(opts.seed) or 0))
    local mixed = seed + matchIndex * 7919 + player * 1543
    mixed = (mixed * 31 + matchIndex * 17 + player * 13) % 1000003
    return pool[(mixed % #pool) + 1]
end

local function referencesForMatch(opts, matchIndex)
    if opts.randomPersonalities == true then
        return deterministicReferenceForMatch(opts, matchIndex, 1),
            deterministicReferenceForMatch(opts, matchIndex, 2)
    end
    return normalizedReference(opts.p1Ref), normalizedReference(opts.p2Ref)
end

local function earlyMaxForReference(ref)
    local reference = normalizedReference(ref)
    local configured = EARLY_TURN_MAX_BY_REFERENCE[reference]
    local value = math.floor(tonumber(configured or DEFAULT_EARLY_TURN_MAX) or 10)
    if value < 0 then
        return 0
    end
    return value
end

local function supplyCountForPlayer(state, player)
    return #(state and state.supply and state.supply[player] or {})
end

local function phaseNameForTurn(state, player, round, reference)
    local p1Supply = supplyCountForPlayer(state, 1)
    local p2Supply = supplyCountForPlayer(state, 2)
    if p1Supply <= 0 or p2Supply <= 0 then
        return "endgame"
    end
    if (round or 1) <= earlyMaxForReference(reference) then
        return "early"
    end
    return "mid"
end

local function unitInventoryForPlayer(state, player)
    local inventory = {}
    for _, unit in ipairs(state and state.units or {}) do
        if isLivingFactionUnit(unit, false) and unit.player == player then
            incrementCount(inventory, unit.name or "UNKNOWN", 1)
        end
    end
    for _, unit in ipairs(state and state.supply and state.supply[player] or {}) do
        if unit and unit.name and unit.name ~= "Commandant" then
            incrementCount(inventory, unit.name, 1)
        end
    end
    return inventory
end

local function supplyInventoryForPlayer(state, player)
    local inventory = {}
    for _, unit in ipairs(state and state.supply and state.supply[player] or {}) do
        if unit and unit.name and unit.name ~= "Commandant" then
            incrementCount(inventory, unit.name, 1)
        end
    end
    return inventory
end

local function newCombatDiagnostics()
    return {
        attacks = 0,
        factionAttacks = 0,
        damage = 0,
        kills = 0,
        commandantAttacks = 0,
        commandantDamage = 0,
        rangedAttacks = 0,
        rangedFactionAttacks = 0,
        rangedUsefulAttacks = 0,
        rangedNeutralAttacks = 0,
        rangedZeroDamage = 0,
        rangedDamage = 0,
        rangedKills = 0,
        rangedCommandantAttacks = 0,
        rangedCommandantDamage = 0,
        rangedDistanceSum = 0,
        rangedDistanceCount = 0,
        rangedByUnit = {},
        rangedTargetTypes = {},
        rangedDuelOpenings = 0,
        rangedDuelOpeningKills = 0,
        rangedDuelResolved = 0,
        rangedDuelDirectResponses = 0,
        rangedDuelDirectKills = 0,
        rangedDuelDirectNonLethal = 0,
        rangedDuelCounterDamage = 0,
        rangedDuelThreatResponses = 0,
        rangedDuelThreatKills = 0,
        rangedDuelOtherDamageResponses = 0,
        rangedDuelRepositions = 0,
        rangedDuelNoResponses = 0,
        rangedDuelSameTurnFollowupRemovals = 0,
        rangedDuelTargetRemovedBeforeResponse = 0,
        rangedDuelUnresolved = 0,
        rangedDuelByOpeningUnit = {},
        rangedDuelResponseShapes = {}
    }
end

local function addRangedUnitStat(diag, unitName, field, delta)
    local byUnit = ensureTable(diag.rangedByUnit, unitName or "UNKNOWN")
    incrementCount(byUnit, field, delta or 1)
end

local function addRangedDuelUnitStat(diag, unitName, field, delta)
    local byUnit = ensureTable(diag.rangedDuelByOpeningUnit, unitName or "UNKNOWN")
    incrementCount(byUnit, field, delta or 1)
end

local function recordAttackDiagnostic(state, action, player, diag)
    if not (state and action and action.type == "attack" and diag) then
        return
    end
    local attacker = action.unit and findUnitAt(state, action.unit.row, action.unit.col) or nil
    local target = action.target and findUnitAt(state, action.target.row, action.target.col) or nil
    local attackerName = attacker and attacker.name or "UNKNOWN"
    local targetName = target and target.name or "UNKNOWN"
    local targetHp = unitHp(target)
    local rawDamage = calculateDamage(attacker, target)
    local damage = target and math.min(targetHp, rawDamage) or 0
    local kill = target and targetHp > 0 and damage >= targetHp
    local factionTarget = target and target.player and target.player > 0 and target.player ~= player
    local commandantTarget = factionTarget and target.name == "Commandant"
    local attackEvent = {
        player = player,
        attackerName = attackerName,
        attackerPlayer = attacker and attacker.player or player,
        attackerRow = attacker and attacker.row or action.unit and action.unit.row,
        attackerCol = attacker and attacker.col or action.unit and action.unit.col,
        attackerRanged = isRangedUnit(attacker),
        targetName = targetName,
        targetPlayer = target and target.player or nil,
        targetRow = target and target.row or action.target and action.target.row,
        targetCol = target and target.col or action.target and action.target.col,
        targetRanged = isRangedUnit(target),
        factionTarget = factionTarget == true,
        commandantTarget = commandantTarget == true,
        damage = damage,
        rawDamage = rawDamage,
        kill = kill == true,
        targetHpBefore = targetHp
    }

    diag.attacks = diag.attacks + 1
    if factionTarget then
        diag.factionAttacks = diag.factionAttacks + 1
        diag.damage = diag.damage + damage
        if kill then
            diag.kills = diag.kills + 1
        end
        if commandantTarget then
            diag.commandantAttacks = diag.commandantAttacks + 1
            diag.commandantDamage = diag.commandantDamage + damage
        end
    end

    if not isRangedUnit(attacker) then
        return attackEvent
    end

    diag.rangedAttacks = diag.rangedAttacks + 1
    addRangedUnitStat(diag, attackerName, "attacks", 1)
    incrementCount(diag.rangedTargetTypes, targetName, 1)
    local distance = manhattan(attacker, target)
    if distance then
        diag.rangedDistanceSum = diag.rangedDistanceSum + distance
        diag.rangedDistanceCount = diag.rangedDistanceCount + 1
    end

    if not factionTarget then
        diag.rangedNeutralAttacks = diag.rangedNeutralAttacks + 1
        addRangedUnitStat(diag, attackerName, "neutral", 1)
        if damage <= 0 then
            diag.rangedZeroDamage = diag.rangedZeroDamage + 1
            addRangedUnitStat(diag, attackerName, "zero", 1)
        end
        return attackEvent
    end

    diag.rangedFactionAttacks = diag.rangedFactionAttacks + 1
    diag.rangedDamage = diag.rangedDamage + damage
    addRangedUnitStat(diag, attackerName, "faction", 1)
    addRangedUnitStat(diag, attackerName, "damage", damage)
    if damage > 0 then
        diag.rangedUsefulAttacks = diag.rangedUsefulAttacks + 1
        addRangedUnitStat(diag, attackerName, "useful", 1)
    else
        diag.rangedZeroDamage = diag.rangedZeroDamage + 1
        addRangedUnitStat(diag, attackerName, "zero", 1)
    end
    if kill then
        diag.rangedKills = diag.rangedKills + 1
        addRangedUnitStat(diag, attackerName, "kills", 1)
    end
    if commandantTarget then
        diag.rangedCommandantAttacks = diag.rangedCommandantAttacks + 1
        diag.rangedCommandantDamage = diag.rangedCommandantDamage + damage
        addRangedUnitStat(diag, attackerName, "commandantAttacks", 1)
        addRangedUnitStat(diag, attackerName, "commandantDamage", damage)
    end
    if isRangedUnit(target) then
        diag.rangedDuelOpenings = diag.rangedDuelOpenings + 1
        addRangedDuelUnitStat(diag, attackerName, "openings", 1)
        if kill then
            diag.rangedDuelOpeningKills = diag.rangedDuelOpeningKills + 1
            addRangedDuelUnitStat(diag, attackerName, "openingKills", 1)
        else
            attackEvent.rangedDuelOpening = true
        end
    end
    return attackEvent
end

local function mergeCombatDiagnostics(target, source)
    if not (target and source) then
        return
    end
    local fields = {
        "attacks",
        "factionAttacks",
        "damage",
        "kills",
        "commandantAttacks",
        "commandantDamage",
        "rangedAttacks",
        "rangedFactionAttacks",
        "rangedUsefulAttacks",
        "rangedNeutralAttacks",
        "rangedZeroDamage",
        "rangedDamage",
        "rangedKills",
        "rangedCommandantAttacks",
        "rangedCommandantDamage",
        "rangedDistanceSum",
        "rangedDistanceCount",
        "rangedDuelOpenings",
        "rangedDuelOpeningKills",
        "rangedDuelResolved",
        "rangedDuelDirectResponses",
        "rangedDuelDirectKills",
        "rangedDuelDirectNonLethal",
        "rangedDuelCounterDamage",
        "rangedDuelThreatResponses",
        "rangedDuelThreatKills",
        "rangedDuelOtherDamageResponses",
        "rangedDuelRepositions",
        "rangedDuelNoResponses",
        "rangedDuelSameTurnFollowupRemovals",
        "rangedDuelTargetRemovedBeforeResponse",
        "rangedDuelUnresolved"
    }
    for _, field in ipairs(fields) do
        target[field] = (target[field] or 0) + (source[field] or 0)
    end
    for unitName, stats in pairs(source.rangedByUnit or {}) do
        local targetStats = ensureTable(target.rangedByUnit, unitName)
        mergeCounts(targetStats, stats)
    end
    for unitName, stats in pairs(source.rangedDuelByOpeningUnit or {}) do
        local targetStats = ensureTable(target.rangedDuelByOpeningUnit, unitName)
        mergeCounts(targetStats, stats)
    end
    mergeCounts(target.rangedTargetTypes, source.rangedTargetTypes)
    mergeCounts(target.rangedDuelResponseShapes, source.rangedDuelResponseShapes)
end

local function sameBoardUnit(event, unit)
    return event
        and unit
        and unit.player == event.targetPlayer
        and unit.name == event.targetName
        and unit.row == event.targetRow
        and unit.col == event.targetCol
end

local function pendingDuelFromAttack(event, round)
    return {
        openingTurn = round,
        openerPlayer = event.player,
        responderPlayer = event.targetPlayer,
        attackerName = event.attackerName,
        attackerRow = event.attackerRow,
        attackerCol = event.attackerCol,
        targetName = event.targetName,
        targetRow = event.targetRow,
        targetCol = event.targetCol,
        openingDamage = event.damage,
        targetHpBefore = event.targetHpBefore
    }
end

local function dropRangedDuelsWithoutResponder(state, pendingByPlayer, player, diag)
    local pending = pendingByPlayer[player] or {}
    if #pending == 0 then
        return
    end
    local kept = {}
    for _, event in ipairs(pending) do
        local target = findUnitAt(state, event.targetRow, event.targetCol)
        if sameBoardUnit(event, target) then
            kept[#kept + 1] = event
        else
            diag.rangedDuelTargetRemovedBeforeResponse =
                (diag.rangedDuelTargetRemovedBeforeResponse or 0) + 1
            incrementCount(diag.rangedDuelResponseShapes, "target_removed_before_response", 1)
        end
    end
    pendingByPlayer[player] = kept
end

local function actionMovesDuelTarget(event, detail)
    return event
        and detail
        and detail.type == "move"
        and detail.unitName == event.targetName
        and detail.fromRow == event.targetRow
        and detail.fromCol == event.targetCol
end

local function directDuelResponse(event, attackEvent)
    return event
        and attackEvent
        and attackEvent.factionTarget == true
        and attackEvent.targetPlayer == event.openerPlayer
        and attackEvent.targetName == event.attackerName
        and attackEvent.targetRow == event.attackerRow
        and attackEvent.targetCol == event.attackerCol
end

local function rangedThreatResponse(event, attackEvent)
    return event
        and attackEvent
        and attackEvent.factionTarget == true
        and attackEvent.targetPlayer == event.openerPlayer
        and attackEvent.targetRanged == true
end

local function resolveRangedDuelResponses(player, pendingByPlayer, attackEvents, actionDetails, diag)
    local pending = pendingByPlayer[player] or {}
    if #pending == 0 then
        return
    end

    for _, event in ipairs(pending) do
        local direct = nil
        local threat = nil
        local otherDamage = nil
        for _, attackEvent in ipairs(attackEvents or {}) do
            if directDuelResponse(event, attackEvent) then
                direct = attackEvent
                break
            elseif not threat and rangedThreatResponse(event, attackEvent) then
                threat = attackEvent
            elseif not otherDamage and attackEvent.factionTarget == true and (attackEvent.damage or 0) > 0 then
                otherDamage = attackEvent
            end
        end

        local moved = false
        for _, detail in ipairs(actionDetails or {}) do
            if actionMovesDuelTarget(event, detail) then
                moved = true
                break
            end
        end

        diag.rangedDuelResolved = (diag.rangedDuelResolved or 0) + 1
        if direct then
            diag.rangedDuelDirectResponses = (diag.rangedDuelDirectResponses or 0) + 1
            diag.rangedDuelCounterDamage = (diag.rangedDuelCounterDamage or 0) + (direct.damage or 0)
            if direct.kill then
                diag.rangedDuelDirectKills = (diag.rangedDuelDirectKills or 0) + 1
                incrementCount(diag.rangedDuelResponseShapes, "direct_kill", 1)
            else
                diag.rangedDuelDirectNonLethal = (diag.rangedDuelDirectNonLethal or 0) + 1
                incrementCount(diag.rangedDuelResponseShapes, "direct_nonlethal_return_fire", 1)
            end
        elseif threat then
            diag.rangedDuelThreatResponses = (diag.rangedDuelThreatResponses or 0) + 1
            if threat.kill then
                diag.rangedDuelThreatKills = (diag.rangedDuelThreatKills or 0) + 1
                incrementCount(diag.rangedDuelResponseShapes, "other_ranged_threat_kill", 1)
            else
                incrementCount(diag.rangedDuelResponseShapes, "other_ranged_threat_damage", 1)
            end
        elseif otherDamage then
            diag.rangedDuelOtherDamageResponses = (diag.rangedDuelOtherDamageResponses or 0) + 1
            incrementCount(diag.rangedDuelResponseShapes, "other_damage", 1)
        elseif moved then
            diag.rangedDuelRepositions = (diag.rangedDuelRepositions or 0) + 1
            incrementCount(diag.rangedDuelResponseShapes, "reposition", 1)
        else
            diag.rangedDuelNoResponses = (diag.rangedDuelNoResponses or 0) + 1
            incrementCount(diag.rangedDuelResponseShapes, "no_response", 1)
        end
    end
    pendingByPlayer[player] = {}
end

local function resolveSameTurnRangedDuelFollowups(state, pendingByPlayer, responderPlayer, openerPlayer, round, diag)
    local pending = pendingByPlayer[responderPlayer] or {}
    if #pending == 0 then
        return
    end
    local kept = {}
    for _, event in ipairs(pending) do
        local openedThisTurn = event.openingTurn == round and event.openerPlayer == openerPlayer
        local target = openedThisTurn and findUnitAt(state, event.targetRow, event.targetCol) or nil
        if openedThisTurn and not sameBoardUnit(event, target) then
            diag.rangedDuelSameTurnFollowupRemovals =
                (diag.rangedDuelSameTurnFollowupRemovals or 0) + 1
            incrementCount(diag.rangedDuelResponseShapes, "same_turn_followup_removed", 1)
        else
            kept[#kept + 1] = event
        end
    end
    pendingByPlayer[responderPlayer] = kept
end

local function flushUnresolvedRangedDuels(pendingByPlayer, diag)
    for player = 1, 2 do
        local pending = pendingByPlayer[player] or {}
        if #pending > 0 then
            diag.rangedDuelUnresolved = (diag.rangedDuelUnresolved or 0) + #pending
            incrementCount(diag.rangedDuelResponseShapes, "unresolved_match_end", #pending)
            pendingByPlayer[player] = {}
        end
    end
end

local function distanceBucket(distance)
    if distance == nil or distance == math.huge then
        return "none"
    end
    if distance <= 1 then
        return "adjacent"
    end
    if distance == 2 then
        return "range2"
    end
    if distance <= 4 then
        return "range3_4"
    end
    return "range5_plus"
end

local function factionDistanceDiagnostics(state, player)
    local opponent = (player == 1) and 2 or 1
    local ownCombat = {}
    local enemyCombat = {}
    local ownFaction = {}
    local enemyFaction = {}

    for _, unit in ipairs(state.units or {}) do
        if isLivingFactionUnit(unit, false) then
            if unit.player == player then
                ownCombat[#ownCombat + 1] = unit
            elseif unit.player == opponent then
                enemyCombat[#enemyCombat + 1] = unit
            end
        end
        if isLivingFactionUnit(unit, true) then
            if unit.player == player then
                ownFaction[#ownFaction + 1] = unit
            elseif unit.player == opponent then
                enemyFaction[#enemyFaction + 1] = unit
            end
        end
    end

    local closestCombat = math.huge
    for _, own in ipairs(ownCombat) do
        for _, enemy in ipairs(enemyCombat) do
            closestCombat = math.min(closestCombat, manhattan(own, enemy) or math.huge)
        end
    end

    local closestFaction = math.huge
    for _, own in ipairs(ownFaction) do
        for _, enemy in ipairs(enemyFaction) do
            closestFaction = math.min(closestFaction, manhattan(own, enemy) or math.huge)
        end
    end

    local enemyHub = state.commandHubs and state.commandHubs[opponent] or nil
    local ownHub = state.commandHubs and state.commandHubs[player] or nil
    local closestOwnToEnemyHub = math.huge
    local closestEnemyToOwnHub = math.huge
    for _, own in ipairs(ownCombat) do
        closestOwnToEnemyHub = math.min(closestOwnToEnemyHub, manhattan(own, enemyHub) or math.huge)
    end
    for _, enemy in ipairs(enemyCombat) do
        closestEnemyToOwnHub = math.min(closestEnemyToOwnHub, manhattan(enemy, ownHub) or math.huge)
    end

    return {
        ownCombatUnits = #ownCombat,
        enemyCombatUnits = #enemyCombat,
        closestCombatDistance = closestCombat ~= math.huge and closestCombat or nil,
        closestFactionDistance = closestFaction ~= math.huge and closestFaction or nil,
        closestOwnToEnemyHub = closestOwnToEnemyHub ~= math.huge and closestOwnToEnemyHub or nil,
        closestEnemyToOwnHub = closestEnemyToOwnHub ~= math.huge and closestEnemyToOwnHub or nil
    }
end

local function isFactionAttackEntry(entry, state, player)
    local target = entry and entry.target or nil
    local action = entry and entry.action or nil
    if not target and action and action.target then
        target = findUnitAt(state, action.target.row, action.target.col)
    end
    return target and target.player and target.player > 0 and target.player ~= player
end

local function countLegalFactionAttackEntries(ai, state, player)
    if not (ai and ai.collectLegalActions and state and player) then
        return 0
    end

    local entries = ai:collectLegalActions(state, {
        aiPlayer = player,
        includeMove = false,
        includeAttack = true,
        includeRepair = false,
        includeDeploy = false,
        allowFullHpHealerRepairException = ACTION_RULES.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    }) or {}

    local count = 0
    for _, entry in ipairs(entries) do
        if isFactionAttackEntry(entry, state, player) then
            count = count + 1
        end
    end
    return count
end

local function countLegalMoveAttackFactionOptions(ai, state, player)
    if not (ai and ai.collectLegalActions and ai.simulateActionSequenceForPlayer and state and player) then
        return 0
    end

    local moves = ai:collectLegalActions(state, {
        aiPlayer = player,
        includeMove = true,
        includeAttack = false,
        includeRepair = false,
        includeDeploy = false,
        allowFullHpHealerRepairException = ACTION_RULES.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    }) or {}

    local options = 0
    local moveLimit = math.min(#moves, 48)
    for index = 1, moveLimit do
        local action = moves[index] and moves[index].action or nil
        if action then
            local afterMove = ai:simulateActionSequenceForPlayer(state, {action}, player, {})
            if afterMove then
                refreshDerivedState(afterMove)
                local attacks = ai:collectLegalActions(afterMove, {
                    aiPlayer = player,
                    includeMove = false,
                    includeAttack = true,
                    includeRepair = false,
                    includeDeploy = false,
                    allowFullHpHealerRepairException = ACTION_RULES.HEALER_FULL_HP_REPAIR_EXCEPTION == true
                }) or {}
                for _, attackEntry in ipairs(attacks) do
                    if isFactionAttackEntry(attackEntry, afterMove, player) then
                        options = options + 1
                        break
                    end
                end
            end
        end
    end
    return options
end

local function buildDrawTurnDiagnostic(ai, state, player, round, drawCounter)
    local distances = factionDistanceDiagnostics(state, player)
    distances.turn = round
    distances.player = player
    distances.drawCounterBefore = drawCounter or 0
    distances.directFactionAttacks = countLegalFactionAttackEntries(ai, state, player)
    distances.moveAttackFactionOptions = countLegalMoveAttackFactionOptions(ai, state, player)
    return distances
end

local function actionTypeList(actions)
    local parts = {}
    for _, action in ipairs(actions or {}) do
        parts[#parts + 1] = tostring(action and action.type or "unknown")
    end
    return table.concat(parts, "+")
end

local function avgFrom(sum, count)
    if not count or count <= 0 then
        return 0
    end
    return sum / count
end

local function newDrawDiagnostics()
    return {
        sampledTurns = 0,
        drawWindowTurns = 0,
        noInteractionTurns = 0,
        noInteractionWithDirectAttack = 0,
        noInteractionWithMoveAttack = 0,
        noInteractionWithAnyCombatOption = 0,
        noInteractionCloseCombatLe2 = 0,
        noInteractionCloseFactionLe2 = 0,
        noInteractionClosestCombatSum = 0,
        noInteractionClosestCombatCount = 0,
        noInteractionClosestFactionSum = 0,
        noInteractionClosestFactionCount = 0,
        distanceBuckets = {},
        actionShapeCounts = {},
        lastTurns = {}
    }
end

local function addRecentDrawTurn(diag, row)
    diag.lastTurns[#diag.lastTurns + 1] = row
    while #diag.lastTurns > 8 do
        table.remove(diag.lastTurns, 1)
    end
end

local function recordDrawTurnDiagnostic(diag, row)
    if not (diag and row) then
        return
    end

    diag.sampledTurns = diag.sampledTurns + 1
    addRecentDrawTurn(diag, row)

    if row.turn < DRAW_START_TURN then
        return
    end

    diag.drawWindowTurns = diag.drawWindowTurns + 1
    if row.interacted then
        return
    end

    diag.noInteractionTurns = diag.noInteractionTurns + 1
    if (row.directFactionAttacks or 0) > 0 then
        diag.noInteractionWithDirectAttack = diag.noInteractionWithDirectAttack + 1
    end
    if (row.moveAttackFactionOptions or 0) > 0 then
        diag.noInteractionWithMoveAttack = diag.noInteractionWithMoveAttack + 1
    end
    if (row.directFactionAttacks or 0) > 0 or (row.moveAttackFactionOptions or 0) > 0 then
        diag.noInteractionWithAnyCombatOption = diag.noInteractionWithAnyCombatOption + 1
    end
    if row.closestCombatDistance then
        diag.noInteractionClosestCombatSum = diag.noInteractionClosestCombatSum + row.closestCombatDistance
        diag.noInteractionClosestCombatCount = diag.noInteractionClosestCombatCount + 1
        if row.closestCombatDistance <= 2 then
            diag.noInteractionCloseCombatLe2 = diag.noInteractionCloseCombatLe2 + 1
        end
    end
    if row.closestFactionDistance then
        diag.noInteractionClosestFactionSum = diag.noInteractionClosestFactionSum + row.closestFactionDistance
        diag.noInteractionClosestFactionCount = diag.noInteractionClosestFactionCount + 1
        if row.closestFactionDistance <= 2 then
            diag.noInteractionCloseFactionLe2 = diag.noInteractionCloseFactionLe2 + 1
        end
    end

    incrementCount(diag.distanceBuckets, distanceBucket(row.closestCombatDistance), 1)
    incrementCount(diag.actionShapeCounts, row.actionTypes ~= "" and row.actionTypes or "none", 1)
end

local function mergeDrawDiagnostics(target, source)
    if not (target and source) then
        return
    end

    local numericFields = {
        "sampledTurns",
        "drawWindowTurns",
        "noInteractionTurns",
        "noInteractionWithDirectAttack",
        "noInteractionWithMoveAttack",
        "noInteractionWithAnyCombatOption",
        "noInteractionCloseCombatLe2",
        "noInteractionCloseFactionLe2",
        "noInteractionClosestCombatSum",
        "noInteractionClosestCombatCount",
        "noInteractionClosestFactionSum",
        "noInteractionClosestFactionCount"
    }
    for _, field in ipairs(numericFields) do
        target[field] = (target[field] or 0) + (source[field] or 0)
    end
    for bucket, count in pairs(source.distanceBuckets or {}) do
        incrementCount(target.distanceBuckets, bucket, count)
    end
    for shape, count in pairs(source.actionShapeCounts or {}) do
        incrementCount(target.actionShapeCounts, shape, count)
    end
end

local function newTournamentHygiene()
    return {
        decisions = 0,
        technicalFallback = 0,
        runtimeSanitizerRejected = 0,
        runtimeSanitizerRejectReplacements = 0,
        sanitizerReplacements = 0,
        contracts = {},
        reasons = {},
        fallbackReasons = {},
        fallbackSources = {},
        coreExits = {},
        selectedSources = {},
        sanitizerReasons = {},
        runtimeSanitizerRejectReasons = {}
    }
end

local function recordTournamentHygiene(hygiene, meta)
    if not hygiene then
        return
    end
    if type(meta) ~= "table" then
        incrementCount(hygiene.reasons, "missing_tournament_meta", 1)
        return
    end

    local stats = meta.stats or {}
    hygiene.decisions = hygiene.decisions + 1
    incrementCount(hygiene.contracts, meta.contract or stats.selectedContract or "unknown", 1)
    incrementCount(hygiene.reasons, meta.reason or "unknown", 1)
    if meta.fallbackReason or stats.fallbackReason then
        incrementCount(hygiene.fallbackReasons, meta.fallbackReason or stats.fallbackReason, 1)
    end
    if stats.fallbackSource then
        incrementCount(hygiene.fallbackSources, stats.fallbackSource, 1)
    end
    if stats.coreExit then
        incrementCount(hygiene.coreExits, stats.coreExit, 1)
    end

    local selectedSource = stats.selectedCandidateSource
        or stats.pipelineV2EndSelectedSource
        or stats.pipelineV2MidSelectedSource
        or (meta.selected and meta.selected.candidate and meta.selected.candidate.source)
        or "unknown"
    incrementCount(hygiene.selectedSources, selectedSource, 1)

    if meta.contract == "TECHNICAL_FALLBACK" or stats.fallbackSource == "technical_fallback" then
        hygiene.technicalFallback = hygiene.technicalFallback + 1
    end

    local sanitizerReplacements = tonumber(stats.sanitizerReplacements or meta.sanitizerReplacements) or 0
    hygiene.sanitizerReplacements = hygiene.sanitizerReplacements + sanitizerReplacements
    mergeCounts(hygiene.sanitizerReasons, stats.sanitizerReasonCounts or meta.sanitizerReasonCounts or {})

    if stats.runtimeSanitizerRejected == true or meta.runtimeSanitizerRejected == true then
        hygiene.runtimeSanitizerRejected = hygiene.runtimeSanitizerRejected + 1
        hygiene.runtimeSanitizerRejectReplacements = hygiene.runtimeSanitizerRejectReplacements
            + (tonumber(stats.runtimeSanitizerRejectReplacements or meta.runtimeSanitizerRejectReplacements) or 0)
        mergeCounts(
            hygiene.runtimeSanitizerRejectReasons,
            stats.runtimeSanitizerRejectReasonCounts or meta.runtimeSanitizerRejectReasonCounts or {}
        )
    end
end

local function mergeTournamentHygiene(target, source)
    if not (target and source) then
        return
    end
    target.decisions = target.decisions + (source.decisions or 0)
    target.technicalFallback = target.technicalFallback + (source.technicalFallback or 0)
    target.runtimeSanitizerRejected = target.runtimeSanitizerRejected + (source.runtimeSanitizerRejected or 0)
    target.runtimeSanitizerRejectReplacements =
        target.runtimeSanitizerRejectReplacements + (source.runtimeSanitizerRejectReplacements or 0)
    target.sanitizerReplacements = target.sanitizerReplacements + (source.sanitizerReplacements or 0)
    mergeCounts(target.contracts, source.contracts)
    mergeCounts(target.reasons, source.reasons)
    mergeCounts(target.fallbackReasons, source.fallbackReasons)
    mergeCounts(target.fallbackSources, source.fallbackSources)
    mergeCounts(target.coreExits, source.coreExits)
    mergeCounts(target.selectedSources, source.selectedSources)
    mergeCounts(target.sanitizerReasons, source.sanitizerReasons)
    mergeCounts(target.runtimeSanitizerRejectReasons, source.runtimeSanitizerRejectReasons)
end

local function sortedCountRows(map)
    local rows = {}
    for key, countValue in pairs(map or {}) do
        rows[#rows + 1] = {
            key = tostring(key),
            count = tonumber(countValue) or 0
        }
    end
    table.sort(rows, function(a, b)
        if a.count == b.count then
            return a.key < b.key
        end
        return a.count > b.count
    end)
    return rows
end

local function newSkipDiagnostics()
    return {
        total = 0,
        forcedNoLegal = 0,
        missingProposal = 0,
        rawProposed = 0,
        fallback = 0,
        replaced = 0,
        byReason = {},
        byPhase = {},
        bySource = {},
        byPlayer = {}
    }
end

local function mergeSkipDiagnostics(target, source)
    if not (target and source) then
        return
    end
    target.total = (target.total or 0) + (source.total or 0)
    target.forcedNoLegal = (target.forcedNoLegal or 0) + (source.forcedNoLegal or 0)
    target.missingProposal = (target.missingProposal or 0) + (source.missingProposal or 0)
    target.rawProposed = (target.rawProposed or 0) + (source.rawProposed or 0)
    target.fallback = (target.fallback or 0) + (source.fallback or 0)
    target.replaced = (target.replaced or 0) + (source.replaced or 0)
    mergeCounts(target.byReason, source.byReason)
    mergeCounts(target.byPhase, source.byPhase)
    mergeCounts(target.bySource, source.bySource)
    mergeCounts(target.byPlayer, source.byPlayer)
end

local function recordSkipDiagnostic(diag, player, phase, proposedMissing, proposedRawSkip, replaced, reason, meta)
    if not diag then
        return
    end
    diag.total = (diag.total or 0) + 1
    if reason == "no_legal_actions" then
        diag.forcedNoLegal = (diag.forcedNoLegal or 0) + 1
    end
    if proposedMissing then
        diag.missingProposal = (diag.missingProposal or 0) + 1
    end
    if proposedRawSkip then
        diag.rawProposed = (diag.rawProposed or 0) + 1
    end
    if reason == "skip_fallback" then
        diag.fallback = (diag.fallback or 0) + 1
    end
    if replaced then
        diag.replaced = (diag.replaced or 0) + 1
    end
    incrementCount(diag.byReason, reason or "unknown", 1)
    incrementCount(diag.byPhase, phase or "unknown", 1)
    incrementCount(diag.byPlayer, "P" .. tostring(player or 0), 1)
    local stats = meta and meta.stats or {}
    local source = stats.pipelineV2EndSelectedSource
        or stats.pipelineV2MidSelectedSource
        or stats.pipelineV2SelectedSource
        or stats.coreExit
        or meta and meta.reason
        or "unknown"
    incrementCount(diag.bySource, tostring(source), 1)
end

local function appendCountLine(lines, label, map, limit)
    local rows = sortedCountRows(map)
    if #rows == 0 then
        lines[#lines + 1] = "- " .. label .. ": none"
        return
    end
    local parts = {}
    for index = 1, math.min(#rows, limit or 8) do
        parts[#parts + 1] = string.format("`%s`=%d", rows[index].key, rows[index].count)
    end
    lines[#lines + 1] = "- " .. label .. ": " .. table.concat(parts, ", ")
end

local function personalityOrder(reference)
    local order = {
        marge = 1,
        homer = 2,
        lisa = 3,
        maggie = 4,
        burt = 5,
        barnes = 6,
        burns = 7,
        base = 8
    }
    return order[tostring(reference or "base")] or 99
end

local function newPersonalityStats(reference)
    return {
        reference = reference,
        games = 0,
        asP1 = 0,
        asP2 = 0,
        wins = 0,
        losses = 0,
        draws = 0,
        rounds = 0,
        playerTurns = 0,
        endingPhases = {},
        phaseTurns = {},
        actionTypes = {},
        initialInventory = {},
        remainingSupply = {},
        unitUsage = {}
    }
end

local function personalityStatsFor(aggregate, reference)
    local key = normalizedReference(reference)
    aggregate.personalityStats[key] = aggregate.personalityStats[key] or newPersonalityStats(key)
    return aggregate.personalityStats[key]
end

local function mergeUnitUsage(target, source)
    if not (target and source) then
        return
    end
    for unitName, stats in pairs(source or {}) do
        local out = ensureTable(target, unitName)
        mergeCounts(out, stats)
    end
end

local function recordPersonalityMatch(aggregate, result, player)
    local reference = result.references and result.references[player] or (player == 1 and aggregate.fixedP1Ref or aggregate.fixedP2Ref)
    local stats = personalityStatsFor(aggregate, reference)
    stats.games = stats.games + 1
    stats.rounds = stats.rounds + (result.rounds or 0)
    stats.playerTurns = stats.playerTurns
        + (result.phaseTurnCountsByPlayer and result.phaseTurnCountsByPlayer[player]
            and (
                (result.phaseTurnCountsByPlayer[player].early or 0)
                + (result.phaseTurnCountsByPlayer[player].mid or 0)
                + (result.phaseTurnCountsByPlayer[player].endgame or 0)
            )
            or 0)
    if player == 1 then
        stats.asP1 = stats.asP1 + 1
    else
        stats.asP2 = stats.asP2 + 1
    end

    if result.outcome == "win" and result.winner == player then
        stats.wins = stats.wins + 1
    elseif result.outcome == "win" then
        stats.losses = stats.losses + 1
    else
        stats.draws = stats.draws + 1
    end

    incrementCount(stats.endingPhases, result.endingPhase or "unknown", 1)
    mergeCounts(stats.phaseTurns, result.phaseTurnCountsByPlayer and result.phaseTurnCountsByPlayer[player] or {})
    mergeCounts(stats.actionTypes, result.actionTypeCountsByPlayer and result.actionTypeCountsByPlayer[player] or {})
    mergeCounts(stats.initialInventory, result.initialInventoryByPlayer and result.initialInventoryByPlayer[player] or {})
    mergeCounts(stats.remainingSupply, result.remainingSupplyByPlayer and result.remainingSupplyByPlayer[player] or {})
    mergeUnitUsage(stats.unitUsage, result.unitUsageByPlayer and result.unitUsageByPlayer[player] or {})
end

local function formatPhaseCounts(map)
    local parts = {}
    for _, phase in ipairs({"early", "mid", "endgame", "unknown"}) do
        local count = map and map[phase] or 0
        if count > 0 then
            parts[#parts + 1] = phase .. "=" .. tostring(count)
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function formatTopUnitUsage(unitUsage, limit)
    local rows = {}
    for unitName, stats in pairs(unitUsage or {}) do
        rows[#rows + 1] = {
            unitName = unitName,
            total = stats.total or 0,
            attacks = stats.attack or 0,
            deploys = stats.supply_deploy or 0
        }
    end
    table.sort(rows, function(a, b)
        if a.total == b.total then
            return a.unitName < b.unitName
        end
        return a.total > b.total
    end)
    local parts = {}
    for index = 1, math.min(#rows, limit or 4) do
        local row = rows[index]
        parts[#parts + 1] = string.format(
            "%s=%d(a%d/d%d)",
            row.unitName,
            row.total,
            row.attacks,
            row.deploys
        )
    end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function deployedFromInventory(initial, remaining)
    local available = 0
    local left = 0
    for _, countValue in pairs(initial or {}) do
        available = available + (tonumber(countValue) or 0)
    end
    for _, countValue in pairs(remaining or {}) do
        left = left + (tonumber(countValue) or 0)
    end
    return math.max(0, available - left), available
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

function refreshDerivedState(state)
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
    local p1Ref, p2Ref = referencesForMatch(opts, matchIndex)
    local ai1 = AI.new({factionId = 1})
    local ai2 = AI.new({factionId = 2})
    ai1:setAiReference(p1Ref, "strength_eval_p1")
    ai2:setAiReference(p2Ref, "strength_eval_p2")

    local state = createInitialState(matchSeed, ai1, ai2)
    local stateRef = {state = state}
    setupGridAdapter(ai1, stateRef)
    setupGridAdapter(ai2, stateRef)
    local initialInventoryByPlayer = {
        [1] = unitInventoryForPlayer(state, 1),
        [2] = unitInventoryForPlayer(state, 2)
    }

    local currentPlayer = 1
    local round = 1
    local winner = nil
    local outcome = "draw"
    local reason = "not_finished"
    local endingPhase = nil
    local lastPhase = "setup"
    local playerTurns = 0
    local decisionLatencies = {}
    local actionReplacements = 0
    local replacementReasonCounts = {}
    local actionTypeCounts = {}
    local actionTypeCountsByPlayer = {[1] = {}, [2] = {}}
    local unitUsageByPlayer = {[1] = {}, [2] = {}}
    local skipDiagnostics = newSkipDiagnostics()
    local phaseTurnCounts = {}
    local phaseTurnCountsByPlayer = {[1] = {}, [2] = {}}
    local combatDiagnostics = newCombatDiagnostics()
    local interactionCounter = state.turnsWithoutDamage or 0
    local drawDiagnostics = newDrawDiagnostics()
    local tournamentHygiene = newTournamentHygiene()
    local pendingRangedDuels = {
        [1] = {},
        [2] = {}
    }

    local function recordUnitAction(player, unitName, actionType)
        local resolvedPlayer = player or 0
        local resolvedType = actionType or "unknown"
        local resolvedUnitName = unitName or "UNKNOWN"

        incrementCount(actionTypeCounts, resolvedType, 1)
        incrementCount(actionTypeCountsByPlayer[resolvedPlayer], resolvedType, 1)
        if resolvedType == "skip" then
            return
        end

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
        local currentReference = currentPlayer == 1 and p1Ref or p2Ref
        local turnPhase = phaseNameForTurn(state, currentPlayer, round, currentReference)
        lastPhase = turnPhase

        if not playerHasUnitsOrSupply(state, currentPlayer) then
            winner = (currentPlayer == 1) and 2 or 1
            outcome = "win"
            reason = "no_units_or_supply"
            endingPhase = turnPhase
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
            endingPhase = turnPhase
            break
        end

        local opponent = (currentPlayer == 1) and 2 or 1
        if not playerHasUnitsOrSupply(state, opponent) then
            winner = currentPlayer
            outcome = "win"
            reason = "opponent_no_units_or_supply"
            endingPhase = turnPhase
            break
        end

        local ai = (currentPlayer == 1) and ai1 or ai2
        setupGridAdapter(ai, stateRef)
        ai.gameRuler.currentPlayer = currentPlayer
        dropRangedDuelsWithoutResponder(state, pendingRangedDuels, currentPlayer, combatDiagnostics)
        incrementCount(phaseTurnCounts, turnPhase, 1)
        incrementCount(phaseTurnCountsByPlayer[currentPlayer], turnPhase, 1)

        local turnDrawDiagnostic = nil
        if opts.drawDiagnostics and round >= math.max(1, DRAW_START_TURN - 2) then
            turnDrawDiagnostic = buildDrawTurnDiagnostic(ai, state, currentPlayer, round, interactionCounter)
        end

        local started = os.clock()
        local sequence = ai:getBestSequence(state)
        local tournamentMeta = ai.lastTournamentMeta
        recordTournamentHygiene(tournamentHygiene, tournamentMeta)
        local latencyMs = (os.clock() - started) * 1000
        decisionLatencies[#decisionLatencies + 1] = latencyMs

        local resolvedActions = {}
        local turnAttackEvents = {}
        local turnActionDetails = {}
        for actionIndex = 1, ACTIONS_PER_TURN do
            local proposedRaw = sequence[actionIndex]
            local proposedMissing = proposedRaw == nil
            local proposedRawSkip = proposedRaw and proposedRaw.type == "skip"
            local proposed = proposedRaw or {type = "skip", unit = {row = 1, col = 1}}
            local resolved, replaced, replacementReason = normalizeActionForState(ai, state, currentPlayer, proposed)
            resolvedActions[#resolvedActions + 1] = resolved
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
                if resolved.type == "skip" then
                    recordSkipDiagnostic(
                        skipDiagnostics,
                        currentPlayer,
                        turnPhase,
                        proposedMissing,
                        proposedRawSkip,
                        replaced,
                        replacementReason,
                        tournamentMeta
                    )
                end
                recordUnitAction(currentPlayer, actingUnitName, resolved.type or "unknown")
                turnActionDetails[#turnActionDetails + 1] = {
                    type = resolved.type or "unknown",
                    unitName = actingUnitName,
                    fromRow = resolved.unit and resolved.unit.row or nil,
                    fromCol = resolved.unit and resolved.unit.col or nil,
                    targetRow = resolved.target and resolved.target.row or nil,
                    targetCol = resolved.target and resolved.target.col or nil
                }
            end

            local attackEvent = recordAttackDiagnostic(state, resolved, currentPlayer, combatDiagnostics)
            if attackEvent then
                turnAttackEvents[#turnAttackEvents + 1] = attackEvent
            end
            state, actionInteraction = applyActionToState(ai, state, resolved, currentPlayer)
            stateRef.state = state
            if attackEvent and attackEvent.rangedDuelOpening == true and attackEvent.targetPlayer then
                local targetAfter = findUnitAt(state, attackEvent.targetRow, attackEvent.targetCol)
                if targetAfter
                    and targetAfter.player == attackEvent.targetPlayer
                    and targetAfter.name == attackEvent.targetName
                    and unitHp(targetAfter) > 0 then
                    local pending = pendingRangedDuels[attackEvent.targetPlayer] or {}
                    pending[#pending + 1] = pendingDuelFromAttack(attackEvent, round)
                    pendingRangedDuels[attackEvent.targetPlayer] = pending
                else
                    combatDiagnostics.rangedDuelOpeningKills =
                        (combatDiagnostics.rangedDuelOpeningKills or 0) + 1
                    addRangedDuelUnitStat(combatDiagnostics, attackEvent.attackerName, "openingKills", 1)
                    incrementCount(combatDiagnostics.rangedDuelResponseShapes, "opening_removed_target", 1)
                end
            end

            if actionInteraction then
                turnInteraction = true
            end

            if not state.commandHubs[opponent] then
                winner = currentPlayer
                outcome = "win"
                reason = "commandant_destroyed"
                endingPhase = turnPhase
                break
            end
            if not playerHasUnitsOrSupply(state, opponent) then
                winner = currentPlayer
                outcome = "win"
                reason = "opponent_no_units_or_supply"
                endingPhase = turnPhase
                break
            end

            -- Safety guard: prevent action application stalls from looping forever.
            if resolved.type ~= "skip" and ai:buildActionSequenceSignature({resolved}) == beforeSignature then
                -- no-op by design, signature call is used only to force deterministic formatting path
            end
        end

        resolveRangedDuelResponses(
            currentPlayer,
            pendingRangedDuels,
            turnAttackEvents,
            turnActionDetails,
            combatDiagnostics
        )
        resolveSameTurnRangedDuelFollowups(
            state,
            pendingRangedDuels,
            opponent,
            currentPlayer,
            round,
            combatDiagnostics
        )

        if outcome == "win" then
            break
        end

        if turnDrawDiagnostic then
            turnDrawDiagnostic.interacted = turnInteraction == true
            turnDrawDiagnostic.actionTypes = actionTypeList(resolvedActions)
            turnDrawDiagnostic.drawCounterAfter =
                turnInteraction and 0
                or (round >= DRAW_START_TURN and (interactionCounter + 1) or interactionCounter)
            recordDrawTurnDiagnostic(drawDiagnostics, turnDrawDiagnostic)
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
            endingPhase = turnPhase
            break
        end

        playerTurns = playerTurns + 1
        if opts.maxRounds and round >= opts.maxRounds and currentPlayer == 2 then
            outcome = "draw"
            reason = "max_round_cap"
            winner = nil
            endingPhase = turnPhase
            break
        end

        if currentPlayer == 1 then
            currentPlayer = 2
        else
            currentPlayer = 1
            round = round + 1
        end
    end

    flushUnresolvedRangedDuels(pendingRangedDuels, combatDiagnostics)

    local matchTurns = round
    local latencyMedian = percentile(decisionLatencies, 0.5)
    local latencyP95 = percentile(decisionLatencies, 0.95)

    return {
        matchIndex = matchIndex,
        seed = matchSeed,
        references = {
            [1] = p1Ref,
            [2] = p2Ref
        },
        outcome = outcome,
        winner = winner,
        reason = reason,
        endingPhase = endingPhase or lastPhase,
        rounds = matchTurns,
        playerTurns = playerTurns,
        replacements = actionReplacements,
        replacementReasonCounts = replacementReasonCounts,
        actionTypeCounts = actionTypeCounts,
        actionTypeCountsByPlayer = actionTypeCountsByPlayer,
        unitUsageByPlayer = unitUsageByPlayer,
        skipDiagnostics = skipDiagnostics,
        initialInventoryByPlayer = initialInventoryByPlayer,
        remainingSupplyByPlayer = {
            [1] = supplyInventoryForPlayer(state, 1),
            [2] = supplyInventoryForPlayer(state, 2)
        },
        phaseTurnCounts = phaseTurnCounts,
        phaseTurnCountsByPlayer = phaseTurnCountsByPlayer,
        combatDiagnostics = combatDiagnostics,
        drawDiagnostics = drawDiagnostics,
        tournamentHygiene = tournamentHygiene,
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
        "- Max rounds per match: " .. tostring(opts.maxRounds or "unlimited"),
        opts.randomPersonalities == true
            and ("- Personality mode: `random_per_match` | pool: `" .. referencePoolLabel(opts.personalityPool) .. "`")
            or ("- Personality mode: `fixed` | P1: `" .. tostring(opts.p1Ref) .. "` | P2: `" .. tostring(opts.p2Ref) .. "`"),
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
        "## Personality Breakdown",
        "",
        (#aggregate.personalityLines > 0 and table.concat(aggregate.personalityLines, "\n") or "- none"),
        "",
        "## Outcome Reasons",
        "",
        table.concat(aggregate.reasonLines, "\n"),
        "",
        "## Phase / Tempo",
        "",
        (#aggregate.phaseLines > 0 and table.concat(aggregate.phaseLines, "\n") or "- none"),
        "",
        "## Supply / Unit Deployment",
        "",
        (#aggregate.unitDeploymentLines > 0 and table.concat(aggregate.unitDeploymentLines, "\n") or "- none"),
        "",
        "## Ranged Attack Diagnostics",
        "",
        (#aggregate.rangedLines > 0 and table.concat(aggregate.rangedLines, "\n") or "- none"),
        "",
        "## Draw Diagnostics",
        "",
        (#aggregate.drawDiagnosticLines > 0 and table.concat(aggregate.drawDiagnosticLines, "\n") or "- none"),
        "",
        "## Tournament Runtime Hygiene",
        "",
        (#aggregate.tournamentHygieneLines > 0 and table.concat(aggregate.tournamentHygieneLines, "\n") or "- none"),
        "",
        "## Replacement Reasons",
        "",
        (#aggregate.replacementReasonLines > 0 and table.concat(aggregate.replacementReasonLines, "\n") or "- none"),
        "",
        "## Skip Diagnostics",
        "",
        (#aggregate.skipDiagnosticLines > 0 and table.concat(aggregate.skipDiagnosticLines, "\n") or "- none"),
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
        endingPhaseCounts = {},
        roundsByEndingPhase = {},
        phaseTurnCounts = {},
        phaseTurnCountsByPlayer = {[1] = {}, [2] = {}},
        phaseLines = {},
        unitDeploymentLines = {},
        rangedLines = {},
        drawDiagnosticLines = {},
        drawEndLines = {},
        tournamentHygiene = newTournamentHygiene(),
        tournamentHygieneLines = {},
        replacementReasonLines = {},
        skipDiagnosticLines = {},
        actionTypeLines = {},
        unitUsageLines = {},
        matchLines = {},
        allDecisionLatencies = {},
        replacementReasonCounts = {},
        actionTypeCounts = {},
        actionTypeCountsByPlayer = {[1] = {}, [2] = {}},
        unitUsageByPlayer = {[1] = {}, [2] = {}},
        unitUsageTotal = {},
        initialInventoryByPlayer = {[1] = {}, [2] = {}},
        remainingSupplyByPlayer = {[1] = {}, [2] = {}},
        initialInventoryTotal = {},
        remainingSupplyTotal = {},
        combatDiagnostics = newCombatDiagnostics(),
        drawDiagnostics = newDrawDiagnostics(),
        skipDiagnostics = newSkipDiagnostics(),
        fixedP1Ref = normalizedReference(opts.p1Ref),
        fixedP2Ref = normalizedReference(opts.p2Ref),
        personalityStats = {},
        personalityLines = {},
        matchupCounts = {}
    }

    for matchIndex = 1, opts.matches do
        local result = runMatch(matchIndex, opts)
        recordPersonalityMatch(aggregate, result, 1)
        recordPersonalityMatch(aggregate, result, 2)
        local matchupKey = string.format(
            "%s vs %s",
            tostring(result.references and result.references[1] or aggregate.fixedP1Ref),
            tostring(result.references and result.references[2] or aggregate.fixedP2Ref)
        )
        incrementCount(aggregate.matchupCounts, matchupKey, 1)

        if result.outcome == "win" and result.winner then
            aggregate.wins[result.winner] = (aggregate.wins[result.winner] or 0) + 1
        else
            aggregate.draws = aggregate.draws + 1
        end

        aggregate.roundsSum = aggregate.roundsSum + result.rounds
        aggregate.totalReplacements = aggregate.totalReplacements + (result.replacements or 0)
        aggregate.reasonCounts[result.reason] = (aggregate.reasonCounts[result.reason] or 0) + 1
        local endingPhaseKey = result.endingPhase or "unknown"
        incrementCount(aggregate.endingPhaseCounts, endingPhaseKey, 1)
        local phaseRoundStats = ensureTable(aggregate.roundsByEndingPhase, endingPhaseKey)
        incrementCount(phaseRoundStats, "count", 1)
        incrementCount(phaseRoundStats, "rounds", result.rounds or 0)
        mergeCounts(aggregate.phaseTurnCounts, result.phaseTurnCounts)
        for player = 1, 2 do
            mergeCounts(
                aggregate.phaseTurnCountsByPlayer[player],
                result.phaseTurnCountsByPlayer and result.phaseTurnCountsByPlayer[player] or {}
            )
        end
        for player = 1, 2 do
            mergeCounts(
                aggregate.initialInventoryByPlayer[player],
                result.initialInventoryByPlayer and result.initialInventoryByPlayer[player] or {}
            )
            mergeCounts(
                aggregate.remainingSupplyByPlayer[player],
                result.remainingSupplyByPlayer and result.remainingSupplyByPlayer[player] or {}
            )
            mergeCounts(aggregate.initialInventoryTotal, result.initialInventoryByPlayer and result.initialInventoryByPlayer[player] or {})
            mergeCounts(aggregate.remainingSupplyTotal, result.remainingSupplyByPlayer and result.remainingSupplyByPlayer[player] or {})
        end
        mergeCombatDiagnostics(aggregate.combatDiagnostics, result.combatDiagnostics)
        mergeDrawDiagnostics(aggregate.drawDiagnostics, result.drawDiagnostics)
        mergeTournamentHygiene(aggregate.tournamentHygiene, result.tournamentHygiene)
        mergeSkipDiagnostics(aggregate.skipDiagnostics, result.skipDiagnostics)
        if result.outcome == "draw" then
            local recent = result.drawDiagnostics and result.drawDiagnostics.lastTurns or {}
            local last = recent[#recent]
            if last then
                aggregate.drawEndLines[#aggregate.drawEndLines + 1] = string.format(
                    "- match=%d seed=%d reason=%s turn=%d p=%d streak=%d->%d direct=%d moveAtk=%d closestCombat=%s closestFaction=%s actions=%s",
                    result.matchIndex,
                    result.seed,
                    tostring(result.reason),
                    last.turn or 0,
                    last.player or 0,
                    last.drawCounterBefore or 0,
                    last.drawCounterAfter or 0,
                    last.directFactionAttacks or 0,
                    last.moveAttackFactionOptions or 0,
                    tostring(last.closestCombatDistance or "none"),
                    tostring(last.closestFactionDistance or "none"),
                    tostring(last.actionTypes or "none")
                )
            end
        end
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
            "- Match %d | seed=%d | refs=P1:%s/P2:%s | outcome=%s%s | reason=%s | ending_phase=%s | rounds=%d | replacements=%d | techFallback=%d | rtSanReject=%d | sanitize=%d | latency_p95=%.3fms",
            result.matchIndex,
            result.seed,
            tostring(result.references and result.references[1] or aggregate.fixedP1Ref),
            tostring(result.references and result.references[2] or aggregate.fixedP2Ref),
            result.outcome,
            result.winner and ("(P" .. tostring(result.winner) .. ")") or "",
            tostring(result.reason),
            tostring(result.endingPhase or "unknown"),
            result.rounds,
            result.replacements or 0,
            result.tournamentHygiene and result.tournamentHygiene.technicalFallback or 0,
            result.tournamentHygiene and result.tournamentHygiene.runtimeSanitizerRejected or 0,
            result.tournamentHygiene and result.tournamentHygiene.sanitizerReplacements or 0,
            result.latency.p95Ms or 0
        )

        if opts.verbose then
            print(string.format(
                "[%02d/%02d] refs=P1:%s/P2:%s outcome=%s%s reason=%s rounds=%d replacements=%d p95=%.3fms",
                matchIndex,
                opts.matches,
                tostring(result.references and result.references[1] or aggregate.fixedP1Ref),
                tostring(result.references and result.references[2] or aggregate.fixedP2Ref),
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

    local personalityRows = {}
    for reference, stats in pairs(aggregate.personalityStats or {}) do
        personalityRows[#personalityRows + 1] = {
            reference = reference,
            stats = stats
        }
    end
    table.sort(personalityRows, function(a, b)
        local ao = personalityOrder(a.reference)
        local bo = personalityOrder(b.reference)
        if ao == bo then
            return tostring(a.reference) < tostring(b.reference)
        end
        return ao < bo
    end)
    for _, row in ipairs(personalityRows) do
        local stats = row.stats
        local deployed, available = deployedFromInventory(stats.initialInventory, stats.remainingSupply)
        aggregate.personalityLines[#aggregate.personalityLines + 1] = string.format(
            "- `%s`: games=%d | W/L/D=%d/%d/%d | asP1/asP2=%d/%d | avg_rounds=%.2f | deployed=%d/%d (%s) | actions move/attack/deploy/repair/skip=%d/%d/%d/%d/%d",
            tostring(row.reference),
            stats.games or 0,
            stats.wins or 0,
            stats.losses or 0,
            stats.draws or 0,
            stats.asP1 or 0,
            stats.asP2 or 0,
            avgFrom(stats.rounds or 0, stats.games or 0),
            deployed,
            available,
            formatPercent(deployed, available),
            stats.actionTypes.move or 0,
            stats.actionTypes.attack or 0,
            stats.actionTypes.supply_deploy or 0,
            stats.actionTypes.repair or 0,
            stats.actionTypes.skip or 0
        )
        aggregate.personalityLines[#aggregate.personalityLines + 1] = string.format(
            "  - phases=%s | endings=%s | top_units=%s",
            formatPhaseCounts(stats.phaseTurns),
            formatPhaseCounts(stats.endingPhases),
            formatTopUnitUsage(stats.unitUsage, 4)
        )
    end
    appendCountLine(aggregate.personalityLines, "matchups", aggregate.matchupCounts, 12)

    local phaseOrder = {"early", "mid", "endgame", "unknown"}
    aggregate.phaseLines[#aggregate.phaseLines + 1] =
        string.format("- Avg rounds: `%.2f`", aggregate.avgRounds)
    local endingParts = {}
    for _, phaseName in ipairs(phaseOrder) do
        local count = aggregate.endingPhaseCounts[phaseName] or 0
        if count > 0 then
            local phaseRounds = aggregate.roundsByEndingPhase[phaseName] or {}
            endingParts[#endingParts + 1] = string.format(
                "%s=%d(avg %.2f)",
                phaseName,
                count,
                avgFrom(phaseRounds.rounds or 0, phaseRounds.count or 0)
            )
        end
    end
    aggregate.phaseLines[#aggregate.phaseLines + 1] =
        "- ending phases: " .. (#endingParts > 0 and table.concat(endingParts, ", ") or "none")
    local turnParts = {}
    for _, phaseName in ipairs(phaseOrder) do
        turnParts[#turnParts + 1] = string.format("%s=%d", phaseName, aggregate.phaseTurnCounts[phaseName] or 0)
    end
    aggregate.phaseLines[#aggregate.phaseLines + 1] =
        "- evaluated player-turns by phase: " .. table.concat(turnParts, ", ")
    for player = 1, 2 do
        local playerParts = {}
        for _, phaseName in ipairs(phaseOrder) do
            playerParts[#playerParts + 1] =
                string.format("%s=%d", phaseName, aggregate.phaseTurnCountsByPlayer[player][phaseName] or 0)
        end
        aggregate.phaseLines[#aggregate.phaseLines + 1] =
            string.format("- P%d player-turns by phase: %s", player, table.concat(playerParts, ", "))
    end

    local totalAvailable = 0
    local totalRemainingSupply = 0
    for _, count in pairs(aggregate.initialInventoryTotal or {}) do
        totalAvailable = totalAvailable + count
    end
    for _, count in pairs(aggregate.remainingSupplyTotal or {}) do
        totalRemainingSupply = totalRemainingSupply + count
    end
    local totalDeployed = math.max(0, totalAvailable - totalRemainingSupply)
    aggregate.unitDeploymentLines[#aggregate.unitDeploymentLines + 1] = string.format(
        "- overall deployed from supply pool: `%d/%d` (%s)",
        totalDeployed,
        totalAvailable,
        formatPercent(totalDeployed, totalAvailable)
    )
    for player = 1, 2 do
        local playerAvailable = 0
        local playerRemaining = 0
        for _, count in pairs(aggregate.initialInventoryByPlayer[player] or {}) do
            playerAvailable = playerAvailable + count
        end
        for _, count in pairs(aggregate.remainingSupplyByPlayer[player] or {}) do
            playerRemaining = playerRemaining + count
        end
        local playerDeployed = math.max(0, playerAvailable - playerRemaining)
        aggregate.unitDeploymentLines[#aggregate.unitDeploymentLines + 1] = string.format(
            "- P%d deployed from supply pool: `%d/%d` (%s)",
            player,
            playerDeployed,
            playerAvailable,
            formatPercent(playerDeployed, playerAvailable)
        )
    end
    local deploymentRows = {}
    for unitName, available in pairs(aggregate.initialInventoryTotal or {}) do
        local remaining = aggregate.remainingSupplyTotal[unitName] or 0
        local deployed = math.max(0, available - remaining)
        local usage = aggregate.unitUsageTotal[unitName] or {}
        deploymentRows[#deploymentRows + 1] = {
            unitName = unitName,
            available = available,
            deployed = deployed,
            remaining = remaining,
            actions = usage.total or 0,
            attacks = usage.attack or 0,
            deploys = usage.supply_deploy or 0,
            rate = available > 0 and deployed / available or 0
        }
    end
    table.sort(deploymentRows, function(a, b)
        if a.rate == b.rate then
            if a.actions == b.actions then
                return a.unitName < b.unitName
            end
            return a.actions < b.actions
        end
        return a.rate < b.rate
    end)
    aggregate.unitDeploymentLines[#aggregate.unitDeploymentLines + 1] = "- least used unit types:"
    for index = 1, math.min(#deploymentRows, 8) do
        local row = deploymentRows[index]
        aggregate.unitDeploymentLines[#aggregate.unitDeploymentLines + 1] = string.format(
            "  - `%s`: deployed=%d/%d (%s) | remaining_supply=%d | actions=%d | attacks=%d",
            tostring(row.unitName),
            row.deployed,
            row.available,
            formatPercent(row.deployed, row.available),
            row.remaining,
            row.actions,
            row.attacks
        )
    end

    local combat = aggregate.combatDiagnostics or newCombatDiagnostics()
    aggregate.rangedLines[#aggregate.rangedLines + 1] = string.format(
        "- all attacks: `%d` | faction attacks: `%d` | damage: `%d` | kills: `%d` | commandant damage: `%d`",
        combat.attacks or 0,
        combat.factionAttacks or 0,
        combat.damage or 0,
        combat.kills or 0,
        combat.commandantDamage or 0
    )
    aggregate.rangedLines[#aggregate.rangedLines + 1] = string.format(
        "- ranged attacks: `%d` | useful faction hits: `%d` (%s) | neutral/rock: `%d` | zero-damage: `%d`",
        combat.rangedAttacks or 0,
        combat.rangedUsefulAttacks or 0,
        formatPercent(combat.rangedUsefulAttacks or 0, combat.rangedAttacks or 0),
        combat.rangedNeutralAttacks or 0,
        combat.rangedZeroDamage or 0
    )
    aggregate.rangedLines[#aggregate.rangedLines + 1] = string.format(
        "- ranged damage: `%d` | ranged kills: `%d` | commandant attacks/damage: `%d/%d` | avg ranged distance: `%.2f`",
        combat.rangedDamage or 0,
        combat.rangedKills or 0,
        combat.rangedCommandantAttacks or 0,
        combat.rangedCommandantDamage or 0,
        avgFrom(combat.rangedDistanceSum or 0, combat.rangedDistanceCount or 0)
    )
    local rangedRows = {}
    for unitName, stats in pairs(combat.rangedByUnit or {}) do
        rangedRows[#rangedRows + 1] = {
            unitName = unitName,
            attacks = stats.attacks or 0,
            useful = stats.useful or 0,
            damage = stats.damage or 0,
            kills = stats.kills or 0,
            commandantDamage = stats.commandantDamage or 0,
            neutral = stats.neutral or 0,
            zero = stats.zero or 0
        }
    end
    table.sort(rangedRows, function(a, b)
        if a.attacks == b.attacks then
            return a.unitName < b.unitName
        end
        return a.attacks > b.attacks
    end)
    if #rangedRows > 0 then
        aggregate.rangedLines[#aggregate.rangedLines + 1] = "- ranged by unit:"
        for _, row in ipairs(rangedRows) do
            aggregate.rangedLines[#aggregate.rangedLines + 1] = string.format(
                "  - `%s`: attacks=%d | useful=%d (%s) | damage=%d | kills=%d | commandant_damage=%d | neutral=%d | zero=%d",
                row.unitName,
                row.attacks,
                row.useful,
                formatPercent(row.useful, row.attacks),
                row.damage,
                row.kills,
                row.commandantDamage,
                row.neutral,
                row.zero
            )
        end
    end
    aggregate.rangedLines[#aggregate.rangedLines + 1] = "- ranged duel diagnostics:"
    aggregate.rangedLines[#aggregate.rangedLines + 1] = string.format(
        "  - openings=%d | opening_kills=%d | resolved_next_turn=%d | unresolved=%d",
        combat.rangedDuelOpenings or 0,
        combat.rangedDuelOpeningKills or 0,
        combat.rangedDuelResolved or 0,
        combat.rangedDuelUnresolved or 0
    )
    aggregate.rangedLines[#aggregate.rangedLines + 1] = string.format(
        "  - responses: direct=%d | direct_kills=%d | direct_nonlethal=%d | counter_damage=%d | other_ranged_threat=%d | other_ranged_kills=%d | other_damage=%d | reposition=%d | no_response=%d | same_turn_followup_removed=%d | target_removed_before_response=%d",
        combat.rangedDuelDirectResponses or 0,
        combat.rangedDuelDirectKills or 0,
        combat.rangedDuelDirectNonLethal or 0,
        combat.rangedDuelCounterDamage or 0,
        combat.rangedDuelThreatResponses or 0,
        combat.rangedDuelThreatKills or 0,
        combat.rangedDuelOtherDamageResponses or 0,
        combat.rangedDuelRepositions or 0,
        combat.rangedDuelNoResponses or 0,
        combat.rangedDuelSameTurnFollowupRemovals or 0,
        combat.rangedDuelTargetRemovedBeforeResponse or 0
    )
    appendCountLine(aggregate.rangedLines, "ranged duel response shapes", combat.rangedDuelResponseShapes, 8)
    local duelRows = {}
    for unitName, stats in pairs(combat.rangedDuelByOpeningUnit or {}) do
        duelRows[#duelRows + 1] = {
            unitName = unitName,
            openings = stats.openings or 0,
            openingKills = stats.openingKills or 0
        }
    end
    table.sort(duelRows, function(a, b)
        if a.openings == b.openings then
            return a.unitName < b.unitName
        end
        return a.openings > b.openings
    end)
    if #duelRows > 0 then
        aggregate.rangedLines[#aggregate.rangedLines + 1] = "  - duel openings by unit:"
        for _, row in ipairs(duelRows) do
            aggregate.rangedLines[#aggregate.rangedLines + 1] = string.format(
                "    - `%s`: openings=%d | opening_kills=%d",
                row.unitName,
                row.openings,
                row.openingKills
            )
        end
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

    local skips = aggregate.skipDiagnostics or newSkipDiagnostics()
    aggregate.skipDiagnosticLines[#aggregate.skipDiagnosticLines + 1] = string.format(
        "- skip slots total: `%d` | forced no-legal: `%d` | raw AI-proposed skip: `%d` | missing second slot filled: `%d` | skip fallback: `%d` | replaced: `%d`",
        skips.total or 0,
        skips.forcedNoLegal or 0,
        skips.rawProposed or 0,
        skips.missingProposal or 0,
        skips.fallback or 0,
        skips.replaced or 0
    )
    appendCountLine(aggregate.skipDiagnosticLines, "skip reasons", skips.byReason, 8)
    appendCountLine(aggregate.skipDiagnosticLines, "skip phases", skips.byPhase, 8)
    appendCountLine(aggregate.skipDiagnosticLines, "skip sources", skips.bySource, 8)
    appendCountLine(aggregate.skipDiagnosticLines, "skip players", skips.byPlayer, 4)

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

    local hygiene = aggregate.tournamentHygiene or newTournamentHygiene()
    aggregate.tournamentHygieneLines[#aggregate.tournamentHygieneLines + 1] =
        string.format("- decisions with tournament meta: `%d`", hygiene.decisions or 0)
    aggregate.tournamentHygieneLines[#aggregate.tournamentHygieneLines + 1] =
        string.format("- technical fallback contracts: `%d`", hygiene.technicalFallback or 0)
    aggregate.tournamentHygieneLines[#aggregate.tournamentHygieneLines + 1] =
        string.format(
            "- runtime sanitizer rejected decisions: `%d` | rejected replacements: `%d`",
            hygiene.runtimeSanitizerRejected or 0,
            hygiene.runtimeSanitizerRejectReplacements or 0
        )
    aggregate.tournamentHygieneLines[#aggregate.tournamentHygieneLines + 1] =
        string.format("- sanitizer replacements reported by tournament: `%d`", hygiene.sanitizerReplacements or 0)
    appendCountLine(aggregate.tournamentHygieneLines, "contracts", hygiene.contracts)
    appendCountLine(aggregate.tournamentHygieneLines, "core exits", hygiene.coreExits)
    appendCountLine(aggregate.tournamentHygieneLines, "fallback sources", hygiene.fallbackSources)
    appendCountLine(aggregate.tournamentHygieneLines, "selected sources", hygiene.selectedSources)
    appendCountLine(aggregate.tournamentHygieneLines, "fallback reasons", hygiene.fallbackReasons)
    appendCountLine(aggregate.tournamentHygieneLines, "runtime sanitizer reject reasons", hygiene.runtimeSanitizerRejectReasons)
    appendCountLine(aggregate.tournamentHygieneLines, "sanitizer reasons", hygiene.sanitizerReasons)

    if not opts.drawDiagnostics then
        aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
            "- disabled; pass `--draw-diagnostics` to collect distance/combat-option draw metrics"
        return aggregate
    end

    local drawDiag = aggregate.drawDiagnostics or newDrawDiagnostics()
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        string.format("- sampled draw-window/player-turns: `%d`", drawDiag.drawWindowTurns or 0)
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        string.format("- no-interaction turns inside draw window: `%d`", drawDiag.noInteractionTurns or 0)
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        string.format("- no-interaction despite direct faction attack: `%d`", drawDiag.noInteractionWithDirectAttack or 0)
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        string.format("- no-interaction despite move+attack option: `%d`", drawDiag.noInteractionWithMoveAttack or 0)
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        string.format("- no-interaction despite any combat option: `%d`", drawDiag.noInteractionWithAnyCombatOption or 0)
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        string.format("- no-interaction with combat units distance <= 2: `%d`", drawDiag.noInteractionCloseCombatLe2 or 0)
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        string.format("- no-interaction with any faction distance <= 2: `%d`", drawDiag.noInteractionCloseFactionLe2 or 0)
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        string.format(
            "- avg closest combat distance on no-interaction: `%.2f`",
            avgFrom(drawDiag.noInteractionClosestCombatSum, drawDiag.noInteractionClosestCombatCount)
        )
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        string.format(
            "- avg closest faction distance on no-interaction: `%.2f`",
            avgFrom(drawDiag.noInteractionClosestFactionSum, drawDiag.noInteractionClosestFactionCount)
        )

    local bucketOrder = {"adjacent", "range2", "range3_4", "range5_plus", "none"}
    local bucketParts = {}
    for _, bucket in ipairs(bucketOrder) do
        bucketParts[#bucketParts + 1] = string.format("%s=%d", bucket, (drawDiag.distanceBuckets or {})[bucket] or 0)
    end
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        "- no-interaction closest-combat buckets: " .. table.concat(bucketParts, ", ")

    local shapeRows = {}
    for shape, count in pairs(drawDiag.actionShapeCounts or {}) do
        shapeRows[#shapeRows + 1] = {shape = shape, count = count}
    end
    table.sort(shapeRows, function(a, b)
        if a.count == b.count then
            return a.shape < b.shape
        end
        return a.count > b.count
    end)
    local shapeParts = {}
    for i = 1, math.min(#shapeRows, 8) do
        shapeParts[#shapeParts + 1] = string.format("%s=%d", shapeRows[i].shape, shapeRows[i].count)
    end
    aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] =
        "- no-interaction action shapes: " .. (#shapeParts > 0 and table.concat(shapeParts, ", ") or "none")

    if #aggregate.drawEndLines > 0 then
        aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] = ""
        aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] = "Draw endings:"
        for _, line in ipairs(aggregate.drawEndLines) do
            aggregate.drawDiagnosticLines[#aggregate.drawDiagnosticLines + 1] = line
        end
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
