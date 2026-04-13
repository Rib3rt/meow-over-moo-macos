-- Main AI Class - Refactored for Maintainability
-- This is the main AI controller that coordinates all AI modules

local function safeRequire(moduleName)
    local success, module = pcall(require, moduleName)
    if not success then
        error("Failed to load module '" .. moduleName .. "': " .. tostring(module))
    end
    return module
end

local aiConfig = require('ai_config')
local aiState = require('ai_state')
local aiMovement = require('ai_movement')
local aiEvaluation = require('ai_evaluation')
local aiSafety = require('ai_safety')
local aiInfluence = require('ai_influence')
local unitsInfo = safeRequire('unitsInfo')
local logger = require("logger")

local AI_PARAMS = aiConfig.AI_PARAMS or {}
local schedulerConfig = AI_PARAMS.SCHEDULER or {}
local loggingConfig = AI_PARAMS.LOGGING or {}
local symbolConfig = loggingConfig.UNIT_SYMBOL or {}
local runtimeConfig = AI_PARAMS.RUNTIME or {}
local profileConfig = AI_PARAMS.PROFILE or {}

local DEFAULT_DELAY = schedulerConfig.DEFAULT_DELAY
local POLL_INTERVAL = schedulerConfig.ANIMATION_POLL_INTERVAL
local DETAIL_DEPTH_DEFAULT = loggingConfig.DETAIL_DEPTH_DEFAULT
local MAX_DETAIL_DEPTH = loggingConfig.MAX_DETAIL_DEPTH
local ARRAY_PREVIEW_LIMIT = loggingConfig.ARRAY_PREVIEW_LIMIT
local OBJECT_PREVIEW_LIMIT = loggingConfig.OBJECT_PREVIEW_LIMIT
local DEFAULT_GRID_SIZE = loggingConfig.DEFAULT_GRID_SIZE
local NEUTRAL_PLAYER_ID = symbolConfig.NEUTRAL_PLAYER_ID
local PLAYER_ONE_ID = symbolConfig.PLAYER_ONE_ID
local PLAYER_TWO_ID = symbolConfig.PLAYER_TWO_ID
local HP_MIN = symbolConfig.HP_MIN
local HP_MAX = symbolConfig.HP_MAX
local ZERO = runtimeConfig.ZERO
local ONE = runtimeConfig.MIN_HP
local UNIFIED_BASE_PROFILE = "base"
local UNIFIED_BASE_PROFILE_TYPE = "fixed"
local DEFAULT_PROFILE_REFERENCE = profileConfig.DEFAULT_REFERENCE or UNIFIED_BASE_PROFILE
local BURNS_ALIAS_REFERENCE = "burns"

local debugMixin = require('ai_debug')
local profileMixin = require('ai_profile')
local mobilityMixin = require('ai_mobility')
local decisionMixin = require('ai_decision')


local aiClass = {}
aiClass.__index = aiClass

debugMixin.mixin(aiClass)
profileMixin.mixin(aiClass)
mobilityMixin.mixin(aiClass)
decisionMixin.mixin(aiClass)

function aiClass:scheduleAfterAnimations(delay, callback)
    if not callback then
        return
    end

    delay = delay or DEFAULT_DELAY

    if not self.gameRuler or not self.gameRuler.scheduleAction then
        callback()
        return
    end

    local function waitForAnimations()
        if self.gameRuler.hasActiveAnimations and self.gameRuler:hasActiveAnimations() then
            self.gameRuler:scheduleAction(POLL_INTERVAL, waitForAnimations)
        else
            self.gameRuler:scheduleAction(delay, callback)
        end
    end

    waitForAnimations()
end

function aiClass:getFactionId()
    if not self.factionId or not GAME.isFactionControlledByAI(self.factionId) then
        self.factionId = GAME.getAIFactionId()
    end
    return self.factionId
end

function aiClass:isValidAiReference(reference)
    local ref = tostring(reference or "")
    if ref == "" then
        return false
    end
    local profileParams = (self.AI_PARAMS and self.AI_PARAMS.PROFILE) or {}
    for _, allowed in ipairs(profileParams.TYPES or {}) do
        if ref == tostring(allowed) then
            return true
        end
    end
    return false
end

function aiClass:resolveAiReferenceForController(controller)
    local profileParams = (self.AI_PARAMS and self.AI_PARAMS.PROFILE) or {}
    local aliasMap = profileParams.ALIAS_TO_REFERENCE or {}
    local fallback = tostring(profileParams.DEFAULT_REFERENCE or DEFAULT_PROFILE_REFERENCE)

    if not controller then
        return fallback
    end

    local byId = controller.id and aliasMap[controller.id]
    if byId and self:isValidAiReference(byId) then
        return tostring(byId)
    end

    local byNickname = controller.nickname and aliasMap[controller.nickname]
    if byNickname and self:isValidAiReference(byNickname) then
        return tostring(byNickname)
    end

    if controller.aiReference and self:isValidAiReference(controller.aiReference) then
        return tostring(controller.aiReference)
    end

    return fallback
end

local function countAliveSupplyUnits(state, playerId)
    if not state or not state.supply or not playerId then
        return ZERO
    end

    local supply = state.supply[playerId] or {}
    local count = ZERO
    for _, unit in ipairs(supply) do
        if unit then
            local hp = unit.currentHp or unit.startingHp or ONE
            if hp > ZERO then
                count = count + ONE
            end
        end
    end
    return count
end

local function getCombatStats(state, playerId)
    local totalHp = ZERO
    local count = ZERO
    for _, unit in ipairs((state and state.units) or {}) do
        if unit
            and unit.player == playerId
            and unit.name ~= "Rock"
            and unit.name ~= "Commandant" then
            local hp = unit.currentHp or unit.startingHp or ZERO
            if hp > ZERO then
                totalHp = totalHp + hp
                count = count + ONE
            end
        end
    end
    return totalHp, count
end

function aiClass:getDynamicAliasConfig(reference)
    local profileParams = (self.AI_PARAMS and self.AI_PARAMS.PROFILE) or {}
    local dynamicAlias = profileParams.DYNAMIC_ALIAS or {}
    return dynamicAlias[tostring(reference or "")]
end

function aiClass:selectBurnsReference(state, factionId, opts)
    local options = opts or {}
    local burnsConfig = self:getDynamicAliasConfig(BURNS_ALIAS_REFERENCE) or {}
    local rules = burnsConfig.RULES or {}
    local owner = factionId or self.factionId
    local neutralRef = tostring(burnsConfig.NEUTRAL_REF or UNIFIED_BASE_PROFILE)
    local balancedRef = tostring(burnsConfig.BALANCED_REF or "maggie")
    local aggressiveRef = tostring(burnsConfig.AGGRESSIVE_REF or "burt")
    local defenseHardRef = tostring(burnsConfig.DEFENSE_HARD_REF or "marge")
    local defenseSoftRef = tostring(burnsConfig.DEFENSE_SOFT_REF or "homer")

    if not self:isValidAiReference(neutralRef) then
        neutralRef = UNIFIED_BASE_PROFILE
    end
    if not self:isValidAiReference(balancedRef) then
        balancedRef = "maggie"
    end
    if not self:isValidAiReference(aggressiveRef) then
        aggressiveRef = "burt"
    end
    if not self:isValidAiReference(defenseHardRef) then
        defenseHardRef = "marge"
    end
    if not self:isValidAiReference(defenseSoftRef) then
        defenseSoftRef = "homer"
    end

    if burnsConfig.ENABLED == false then
        return {
            reference = neutralRef,
            reason = "disabled",
            emergency = false,
            changed = false
        }
    end

    if not owner then
        return {
            reference = neutralRef,
            reason = "missing_faction",
            emergency = false,
            changed = false
        }
    end

    self.dynamicReferenceStateByFaction = self.dynamicReferenceStateByFaction or {}
    local factionState = self.dynamicReferenceStateByFaction[owner]
    if not factionState then
        factionState = {}
        self.dynamicReferenceStateByFaction[owner] = factionState
    end

    local currentTurn = (state and (state.currentTurn or state.turnNumber))
        or (GAME and GAME.CURRENT and GAME.CURRENT.TURN)
        or ONE
    local lockEnabled = tostring(burnsConfig.SWITCH_MODE or "turn_lock") == "turn_lock"
    local holdTurns = math.max(ONE, tonumber(burnsConfig.MIN_HOLD_OWN_TURNS) or 2)
    local applyLock = options.lock ~= false

    if options.lock == false
        and factionState.activeReference
        and factionState.lastResolvedTurn == currentTurn then
        return {
            reference = factionState.activeReference,
            reason = factionState.lastReason or "cached",
            emergency = false,
            changed = false,
            lockUntilTurn = factionState.lockUntilTurn,
            faction = owner,
            turn = currentTurn
        }
    end

    if not state then
        local fallbackRef = factionState.activeReference or neutralRef
        return {
            reference = fallbackRef,
            reason = "missing_state",
            emergency = false,
            changed = false,
            lockUntilTurn = factionState.lockUntilTurn,
            faction = owner,
            turn = currentTurn
        }
    end

    local playerOne = PLAYER_ONE_ID or 1
    local playerTwo = PLAYER_TWO_ID or 2
    local enemy = (owner == playerOne) and playerTwo or playerOne
    local ownHub = state.commandHubs and state.commandHubs[owner]
    local enemyHub = state.commandHubs and state.commandHubs[enemy]
    local ownHubHp = ownHub and (ownHub.currentHp or ownHub.startingHp or ZERO) or ZERO
    local enemyHubHp = enemyHub and (enemyHub.currentHp or enemyHub.startingHp or ZERO) or ZERO
    local ownCombatHp, ownCombatCount = getCombatStats(state, owner)
    local enemyCombatHp, enemyCombatCount = getCombatStats(state, enemy)
    local ownSupplyRemaining = countAliveSupplyUnits(state, owner)
    local enemySupplyRemaining = countAliveSupplyUnits(state, enemy)
    local supplyLead = ownSupplyRemaining - enemySupplyRemaining
    local hpDelta = ownCombatHp - enemyCombatHp
    local winChance = self:calculateWinningPercentage(state) or 50

    local contactDistanceThreshold = math.max(ONE, tonumber(rules.CONTACT_DISTANCE_THRESHOLD) or 3)
    local recentDamageWindow = math.max(ONE, tonumber(rules.CONTACT_RECENT_DAMAGE_WINDOW) or 2)
    local closeContact = false
    for _, friendly in ipairs(state.units or {}) do
        if friendly
            and friendly.player == owner
            and friendly.name ~= "Rock"
            and friendly.name ~= "Commandant" then
            for _, enemyUnit in ipairs(state.units or {}) do
                if enemyUnit
                    and enemyUnit.player == enemy
                    and enemyUnit.name ~= "Rock"
                    and enemyUnit.name ~= "Commandant" then
                    local dist = math.abs((friendly.row or ZERO) - (enemyUnit.row or ZERO))
                        + math.abs((friendly.col or ZERO) - (enemyUnit.col or ZERO))
                    if dist <= contactDistanceThreshold then
                        closeContact = true
                        break
                    end
                end
            end
        end
        if closeContact then
            break
        end
    end
    local turnsWithoutDamage = state.turnsWithoutDamage
    if turnsWithoutDamage == nil then
        turnsWithoutDamage = math.huge
    end
    local recentDamageSignal = turnsWithoutDamage <= recentDamageWindow
    local contactTriggered = closeContact or recentDamageSignal

    local projectedDistanceBuffer = math.max(ZERO, tonumber(rules.PROJECTED_DISTANCE_BUFFER) or 2)
    local immediateThreatLevel = ZERO
    local immediateThreatUnits = ZERO
    local projectedThreatLevel = ZERO
    local projectedThreatUnits = ZERO

    if ownHub then
        for _, enemyUnit in ipairs(state.units or {}) do
            if enemyUnit
                and enemyUnit.player == enemy
                and enemyUnit.name ~= "Rock"
                and enemyUnit.name ~= "Commandant" then
                local stats = self.unitStats and self.unitStats[enemyUnit.name] or {}
                local atkDamage = enemyUnit.atkDamage or stats.atkDamage or ZERO
                local atkRange = enemyUnit.atkRange or stats.atkRange or ONE
                local moveRange = enemyUnit.move or stats.move or ZERO
                local distance = math.abs((enemyUnit.row or ZERO) - ownHub.row) + math.abs((enemyUnit.col or ZERO) - ownHub.col)
                local attackPattern = enemyUnit.attackPattern or stats.attackPattern
                local directThreat = false
                if atkDamage > ZERO and distance <= atkRange then
                    if attackPattern == "los" then
                        directThreat = self:hasLineOfSight(state, enemyUnit, ownHub)
                    else
                        directThreat = true
                    end
                end
                local moveAttackThreat = atkDamage > ZERO and distance <= (moveRange + atkRange)

                if directThreat or moveAttackThreat then
                    local threatScore = (atkDamage * 40) + math.max(ZERO, (moveRange + atkRange - distance + ONE) * 15)
                    if directThreat then
                        threatScore = threatScore + 40
                    end
                    immediateThreatLevel = immediateThreatLevel + threatScore
                    immediateThreatUnits = immediateThreatUnits + ONE
                elseif atkDamage > ZERO and distance <= (moveRange + atkRange + projectedDistanceBuffer) then
                    local projectedScore = (atkDamage * 30) + math.max(ZERO, (moveRange + atkRange + projectedDistanceBuffer - distance + ONE) * 10)
                    projectedThreatLevel = projectedThreatLevel + projectedScore
                    projectedThreatUnits = projectedThreatUnits + ONE
                end
            end
        end
    end

    local immediateHubHpCritical = tonumber(rules.IMMEDIATE_HUB_HP_CRITICAL) or 6
    local immediateThreatLevelMin = tonumber(rules.IMMEDIATE_THREAT_LEVEL_MIN) or 120
    local immediateThreatUnitsMin = math.max(ONE, tonumber(rules.IMMEDIATE_THREAT_UNITS_MIN) or ONE)
    local projectedThreatLevelMin = tonumber(rules.PROJECTED_THREAT_LEVEL_MIN) or 140
    local projectedThreatUnitsMin = math.max(ONE, tonumber(rules.PROJECTED_THREAT_UNITS_MIN) or 2)
    local advantageWinChanceMin = tonumber(rules.ADVANTAGE_WIN_CHANCE_MIN) or 54
    local advantageHpDeltaMin = tonumber(rules.ADVANTAGE_HP_DELTA_MIN) or 3
    local advantageSupplyLeadMin = tonumber(rules.ADVANTAGE_SUPPLY_LEAD_MIN) or ONE
    local advantageMinTurn = math.max(ONE, tonumber(rules.ADVANTAGE_MIN_TURN) or 4)

    local emergencyTriggered = burnsConfig.EMERGENCY_FORCE_DEFENSE ~= false and (
        ownHubHp <= immediateHubHpCritical
        or immediateThreatLevel >= immediateThreatLevelMin
        or immediateThreatUnits >= immediateThreatUnitsMin
    )

    local selected = neutralRef
    local reason = "neutral"
    if emergencyTriggered then
        selected = defenseHardRef
        reason = "immediate_hub_threat"
    elseif projectedThreatLevel >= projectedThreatLevelMin and projectedThreatUnits >= projectedThreatUnitsMin then
        selected = defenseSoftRef
        reason = "projected_hub_threat"
    elseif currentTurn >= advantageMinTurn
        and contactTriggered
        and winChance >= advantageWinChanceMin
        and (hpDelta >= advantageHpDeltaMin or supplyLead >= advantageSupplyLeadMin) then
        selected = aggressiveRef
        reason = "advantage_pressure"
    elseif contactTriggered then
        selected = balancedRef
        reason = "contact_balance"
    end

    local lockedRef = selected
    local lockReason = reason
    if lockEnabled and not emergencyTriggered and factionState.lockedReference and factionState.lockUntilTurn
        and currentTurn <= factionState.lockUntilTurn then
        lockedRef = factionState.lockedReference
        lockReason = "hold_lock"
    end

    local chosenRef = lockedRef
    if not self:isValidAiReference(chosenRef) or chosenRef == BURNS_ALIAS_REFERENCE then
        chosenRef = neutralRef
    end

    local previous = factionState.activeReference
    local changed = previous ~= chosenRef

    if applyLock then
        factionState.activeReference = chosenRef
        factionState.lastReason = lockReason
        factionState.lastResolvedTurn = currentTurn
        factionState.metrics = {
            immediateThreatLevel = immediateThreatLevel,
            immediateThreatUnits = immediateThreatUnits,
            projectedThreatLevel = projectedThreatLevel,
            projectedThreatUnits = projectedThreatUnits,
            contactTriggered = contactTriggered,
            closeContact = closeContact,
            recentDamageSignal = recentDamageSignal,
            winChance = winChance,
            supplyLead = supplyLead,
            hpDelta = hpDelta,
            ownSupplyRemaining = ownSupplyRemaining,
            enemySupplyRemaining = enemySupplyRemaining,
            ownHubHp = ownHubHp,
            enemyHubHp = enemyHubHp,
            ownCombatCount = ownCombatCount,
            enemyCombatCount = enemyCombatCount
        }
        if lockEnabled then
            if emergencyTriggered then
                factionState.lockedReference = chosenRef
                factionState.lockUntilTurn = currentTurn
            else
                factionState.lockedReference = chosenRef
                factionState.lockUntilTurn = currentTurn + holdTurns - ONE
            end
        end
    end

    if changed and options.logSwitch and DEBUG and DEBUG.AI then
        self:logDecision("BurnsProfile", "Dynamic profile switched", {
            faction = owner,
            turn = currentTurn,
            from = previous or "none",
            to = chosenRef,
            reason = lockReason,
            emergency = emergencyTriggered,
            lockUntilTurn = factionState.lockUntilTurn
        })
    end

    return {
        reference = chosenRef,
        reason = lockReason,
        emergency = emergencyTriggered,
        changed = changed,
        faction = owner,
        turn = currentTurn,
        lockUntilTurn = factionState.lockUntilTurn
    }
end

function aiClass:getEffectiveAiReference(state, opts)
    local options = opts or {}
    local identity = tostring(self.aiReference or DEFAULT_PROFILE_REFERENCE)
    if identity ~= BURNS_ALIAS_REFERENCE then
        return identity
    end

    local owner = options.factionId or self.factionId
    local selection = self:selectBurnsReference(state, owner, options)
    local resolved = selection and selection.reference or UNIFIED_BASE_PROFILE
    if not self:isValidAiReference(resolved) or resolved == BURNS_ALIAS_REFERENCE then
        return UNIFIED_BASE_PROFILE
    end
    return resolved
end

function aiClass:getAiProfileLabel(state, opts)
    local identity = tostring(self.aiReference or DEFAULT_PROFILE_REFERENCE)
    local effective = tostring(self:getEffectiveAiReference(state, opts) or UNIFIED_BASE_PROFILE)
    if identity == BURNS_ALIAS_REFERENCE then
        return string.format("%s->%s", identity, effective)
    end
    return effective
end

function aiClass:setAiReference(reference, reason)
    local profileParams = (self.AI_PARAMS and self.AI_PARAMS.PROFILE) or {}
    local fallback = tostring(profileParams.DEFAULT_REFERENCE or DEFAULT_PROFILE_REFERENCE)
    local requested = tostring(reference or fallback)
    local nextReference = self:isValidAiReference(requested) and requested or fallback
    local changed = self.aiReference ~= nextReference

    self.aiReference = nextReference
    self.profileType = UNIFIED_BASE_PROFILE_TYPE
    self.canChangeProfile = false

    if changed then
        self._scoreConfig = nil
        self._scoreConfigReference = nil
        self._unitProfiles = nil
        self._unitProfilesReference = nil
        self._phaseTempoContext = nil
        self._phaseTempoCountKey = nil
        self._phaseTempoContactKey = nil
        self._phaseTempoEndChoiceKey = nil
        self.strategicPlanState = nil
        self.defenseModeState = nil
        self._referenceResolutionState = nil
        if self.dynamicReferenceStateByFaction and self.factionId then
            self.dynamicReferenceStateByFaction[self.factionId] = nil
        end
    end

    if DEBUG and DEBUG.AI and changed then
        logger.debug("AI", "AI profile reference set:", nextReference, "reason:", reason or "unspecified")
    end

    return nextReference
end

function aiClass:formatDetails(value, depth)
    depth = depth or DETAIL_DEPTH_DEFAULT
    if depth > MAX_DETAIL_DEPTH then
        return "..."
    end

    local valueType = type(value)
    if valueType == "nil" then
        return "nil"
    elseif valueType == "number" or valueType == "boolean" or valueType == "string" then
        return tostring(value)
    elseif valueType == "table" then
        if self:isActionTable(value) then
            return self:describeAction(value)
        end

        local isArray = value[ONE] ~= nil
        local parts = {}

        if isArray then
            local limit = math.min(#value, ARRAY_PREVIEW_LIMIT)
            for i = ONE, limit do
                table.insert(parts, self:formatDetails(value[i], depth + ONE))
            end
            if #value > limit then
                table.insert(parts, "...")
            end
            return "[" .. table.concat(parts, ", ") .. "]"
        else
            local count = ZERO
            for key, val in pairs(value) do
                count = count + ONE
                table.insert(parts, tostring(key) .. "=" .. self:formatDetails(val, depth + ONE))
                if count >= OBJECT_PREVIEW_LIMIT then
                    table.insert(parts, "...")
                    break
                end
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
    else
        return "<" .. valueType .. ">"
    end
end

local function describeUnitSymbol(unit)
    if not unit or not unit.name then
        return " "
    end
    local owner = unit.player or NEUTRAL_PLAYER_ID
    local prefix = (owner == PLAYER_ONE_ID and "P") or (owner == PLAYER_TWO_ID and "E") or "N"
    local base = unit.name:sub(ONE, ONE)
    local hp = math.max(HP_MIN, math.min(HP_MAX, unit.currentHp or unit.startingHp or HP_MIN))
    return string.format("%s%s%d", prefix, base, hp)
end

local function buildPriorityLogWhitelist(maxPriority)
    local whitelist = {}
    if type(maxPriority) ~= "number" or maxPriority < ZERO then
        return whitelist
    end

    for i = ZERO, math.floor(maxPriority) do
        whitelist[string.format("Priority%02d", i)] = true
    end

    return whitelist
end

local MAX_PRIORITY_LOGGED = loggingConfig.MAX_PRIORITY_LOGGED
local LOGGED_PRIORITIES = buildPriorityLogWhitelist(MAX_PRIORITY_LOGGED)

function aiClass:printGrid(state, label)
    if not state or not state.units then
        return
    end

    local gridSize = (GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE) or DEFAULT_GRID_SIZE
    local cells = {}
    for row = ONE, gridSize do
        cells[row] = {}
        for col = ONE, gridSize do
            cells[row][col] = " . "
        end
    end

    for _, unit in ipairs(state.units) do
        if unit.row and unit.col and unit.row >= ONE and unit.col >= ONE and unit.row <= gridSize and unit.col <= gridSize then
            cells[unit.row][unit.col] = string.format("%3s", describeUnitSymbol(unit))
        end
    end

    logger.debug("AI", string.format("  %s", label or "Grid state"))
    logger.debug("AI", "    +" .. string.rep("----", gridSize) .. "+")
    for row = ONE, gridSize do
        local line = "    |"
        for col = ONE, gridSize do
            line = line .. cells[row][col]
        end
        logger.debug("AI", line .. " |")
    end
    logger.debug("AI", "    +" .. string.rep("----", gridSize) .. "+")
end

function aiClass:logDecision(context, message, details)
    if not (DEBUG and DEBUG.AI) then
        return
    end

    if context and context:match("^Priority%d%d") and not LOGGED_PRIORITIES[context] then
        return
    end

    local turn = (GAME and GAME.CURRENT and GAME.CURRENT.TURN) or "?"
    if self._lastLoggedTurn ~= turn then
        self._lastLoggedTurn = turn
        logger.debug("AI", "")
        logger.debug("AI", string.format("TURN %s", tostring(turn)))
        if self._lastLoggedStateSnapshot then
            self:printGrid(self._lastLoggedStateSnapshot, "Board before actions")
        end
    end

    if context == "Execution" and message == "Post-action grid" and self._lastLoggedStateSnapshot then
        self:printGrid(self._lastLoggedStateSnapshot, "Board after sequence")
    elseif context and context:match("^Priority%d%d") then
        logger.debug("AI", string.format("  %s -> %s", context, message or ""))
    else
        local label = context and (context .. ": ") or ""
        local line = string.format("  %s%s", label, message or "")
        if details then
            if details.units ~= nil then
                details.totalUnitsOnGrid = details.units
                details.units = nil
            end
            line = line .. " | " .. self:formatDetails(details)
        end
        logger.debug("AI", line)
    end
end

-- Import normalized configuration
aiClass.AI_PARAMS = aiConfig.AI_PARAMS

function aiClass.new(params)
    local self = setmetatable({}, aiClass)

    params = params or {}
    self.unitStats = unitsInfo:getAllUnitInfo()
    self.unitsInfo = unitsInfo  -- Add reference to unitsInfo module
    self.AI_PARAMS = aiClass.AI_PARAMS

    -- Unified baseline AI profile (resolved at runtime from controller alias when available).
    self.aiReference = DEFAULT_PROFILE_REFERENCE
    self.profileType = UNIFIED_BASE_PROFILE_TYPE
    self.canChangeProfile = false
    self.lastChangedProfileTurn = ZERO
    self.dynamicReferenceStateByFaction = {}
    self._referenceResolutionState = nil

    self.lastDeploymentTurn = ZERO

    self.gameRuler = {}
    self.grid = {}

    self.actionsPhaseStarted = false

    self.transpositionTable = {}
    self.killerMoves = {}
    self.strategicPlanState = nil
    self.defenseModeState = nil
    self.verifierOverrideCount = ZERO
    self.verifierTimeoutCount = ZERO
    self.verifierSiegeRuns = ZERO
    self.verifierSiegeOverrides = ZERO
    self.badDeploySkipped = ZERO
    self.unsupportedAttackRejected = ZERO
    self.rockAttackChosenCount = ZERO
    self.rockAttackStrategicCount = ZERO
    self.fillerAttackAvoidedCount = ZERO
    self.healerFrontlineViolationRejected = ZERO
    self.openingHealerBlockedCount = ZERO
    self.phaseEarlyTurns = ZERO
    self.phaseMidTurns = ZERO
    self.phaseEndTurns = ZERO
    self.midgameContactTriggerCount = ZERO
    self.earlyAttackSuppressedCount = ZERO
    self.openingCounterScoreAppliedCount = ZERO
    self.endgameEtaHubChoiceCount = ZERO
    self.endgameEtaWipeChoiceCount = ZERO
    self.endgameDeploySkippedCount = ZERO
    self.defendHardEnterReason = nil
    self.defendHardExitReason = nil

    -- Module references
    self.aiState = aiState
    self.aiMovement = aiMovement
    self.aiEvaluation = aiEvaluation
    self.aiSafety = aiSafety

    self.factionId = params.factionId or GAME.getAIFactionId()
    self:setAiReference(params.aiReference or self.aiReference, "constructor")

    return self
end

-- Profile, win-percentage, and adaptive strategy methods are provided by ai_profile.lua.

return aiClass
