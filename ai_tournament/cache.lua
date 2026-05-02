local M = {}

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local clone = {}
    seen[value] = clone
    for key, child in pairs(value) do
        clone[deepCopy(key, seen)] = deepCopy(child, seen)
    end
    return clone
end

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function boolFlag(value)
    return value and "1" or "0"
end

local function numOr(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function encodePos(pos)
    if type(pos) ~= "table" then
        return "-1,-1"
    end
    return string.format("%d,%d", numOr(pos.row, -1), numOr(pos.col, -1))
end

local function encodeFirstActionRangedAttack(info)
    if type(info) ~= "table" then
        return "none"
    end

    local attacker = info.attacker or {}
    local target = info.target or {}
    return table.concat({
        tostring(attacker.name or "?"),
        tostring(attacker.player or "?"),
        encodePos(attacker),
        tostring(attacker.atkRange or "?"),
        encodePos(target)
    }, ":")
end

local function encodeUnit(unit)
    return table.concat({
        tostring(unit.player or 0),
        tostring(unit.name or "?"),
        tostring(unit.row or 0),
        tostring(unit.col or 0),
        tostring(unit.currentHp or unit.startingHp or 0),
        tostring(unit.startingHp or 0),
        boolFlag(unit.hasActed == true),
        boolFlag(unit.hasMoved == true),
        tostring(unit.actionsUsed or 0)
    }, ":")
end

local function encodeHub(playerId, hub)
    if type(hub) ~= "table" then
        return string.format("%d:dead", numOr(playerId, -1))
    end

    return table.concat({
        tostring(playerId),
        tostring(hub.row or 0),
        tostring(hub.col or 0),
        tostring(hub.currentHp or hub.startingHp or 0),
        tostring(hub.startingHp or 0)
    }, ":")
end

local function encodeSupplyEntry(index, unit)
    return table.concat({
        tostring(index),
        tostring(unit and unit.name or "?"),
        tostring(unit and (unit.currentHp or unit.startingHp or 0) or 0),
        tostring(unit and (unit.startingHp or 0) or 0)
    }, ":")
end

local function encodeGuardAssignments(assignments)
    if type(assignments) ~= "table" then
        return "none"
    end

    local entries = {}
    for _, key in ipairs(sortedKeys(assignments)) do
        local guard = assignments[key] or {}
        entries[#entries + 1] = table.concat({
            tostring(key),
            tostring(guard.row or 0),
            tostring(guard.col or 0)
        }, ":")
    end

    return table.concat(entries, ",")
end

local function encodeUsedUnits(usedUnits)
    if type(usedUnits) ~= "table" then
        return "none"
    end

    local active = {}
    for key, value in pairs(usedUnits) do
        if value then
            active[#active + 1] = tostring(key)
        end
    end
    table.sort(active)

    if #active == 0 then
        return "none"
    end

    return table.concat(active, ",")
end

local function defaultSequenceSignature(sequence)
    local parts = {}
    for idx, action in ipairs(sequence or {}) do
        if type(action) ~= "table" then
            parts[#parts + 1] = string.format("%d:invalid", idx)
        else
            local actionType = tostring(action.type or "unknown")
            if actionType == "supply_deploy" then
                parts[#parts + 1] = string.format(
                    "%d:supply_deploy:%s#%s@%s",
                    idx,
                    tostring(action.unitName or action.unitType or "?"),
                    tostring(action.unitIndex or "?"),
                    encodePos(action.target)
                )
            elseif actionType == "skip" then
                parts[#parts + 1] = string.format("%d:skip", idx)
            else
                parts[#parts + 1] = string.format(
                    "%d:%s:%s->%s",
                    idx,
                    actionType,
                    encodePos(action.unit),
                    encodePos(action.target)
                )
            end
        end
    end

    return table.concat(parts, "|")
end

local function bumpKind(cacheObj, ctx, kind, field)
    if not kind or kind == "" then
        return
    end

    local byKind = cacheObj.byKind or {}
    local entry = byKind[kind] or {hits = 0, misses = 0}
    entry[field] = (entry[field] or 0) + 1
    byKind[kind] = entry
    cacheObj.byKind = byKind

    local scope = ctx or cacheObj._ctx
    if scope and scope.stats then
        local statName = "cache" .. tostring(kind):sub(1, 1):upper() .. tostring(kind):sub(2) .. tostring(field):sub(1, 1):upper() .. tostring(field):sub(2)
        scope.stats[statName] = (scope.stats[statName] or 0) + 1
    end
end

local function markHit(cacheObj, ctx, kind)
    cacheObj.hits = (cacheObj.hits or 0) + 1
    local scope = ctx or cacheObj._ctx
    if scope and scope.stats then
        scope.stats.cacheHits = (scope.stats.cacheHits or 0) + 1
    end
    bumpKind(cacheObj, ctx, kind, "hits")
end

local function markMiss(cacheObj, ctx, kind)
    cacheObj.misses = (cacheObj.misses or 0) + 1
    local scope = ctx or cacheObj._ctx
    if scope and scope.stats then
        scope.stats.cacheMisses = (scope.stats.cacheMisses or 0) + 1
    end
    bumpKind(cacheObj, ctx, kind, "misses")
end

local function stateSignatureWithMemo(cacheObj, ai, state)
    if state == nil then
        return "nil"
    end

    local memo = cacheObj.stateSignatures
    local byIdentity = memo and memo.byIdentity
    if byIdentity and byIdentity[state] then
        return byIdentity[state]
    end

    local signature = cacheObj.stateSignature(ai, state)

    if byIdentity then
        byIdentity[state] = signature
    end

    return signature
end

function M.new(ctx)
    local cacheObj = {
        stateSignatures = {
            byIdentity = {}
        },
        simulations = {},
        legal = {},
        supply = {},
        _featureStore = {},
        _threatStore = {},
        _extensionStore = {},
        byKind = {},
        hits = 0,
        misses = 0,
        _ctx = ctx
    }

    function cacheObj.stateSignature(ai, state)
        if state == nil then
            return "nil"
        end

        local parts = {}

        local unitEntries = {}
        for _, unit in ipairs(state.units or {}) do
            unitEntries[#unitEntries + 1] = encodeUnit(unit)
        end
        table.sort(unitEntries)
        parts[#parts + 1] = "u=" .. table.concat(unitEntries, ",")

        local hubEntries = {}
        local hubMap = state.commandHubs or {}
        local hubKeys = sortedKeys(hubMap)
        for _, playerId in ipairs(hubKeys) do
            hubEntries[#hubEntries + 1] = encodeHub(playerId, hubMap[playerId])
        end
        parts[#parts + 1] = "h=" .. table.concat(hubEntries, ";")

        local supplyEntries = {}
        local supplyMap = state.supply or {}
        local supplyKeys = sortedKeys(supplyMap)
        for _, playerId in ipairs(supplyKeys) do
            local list = supplyMap[playerId] or {}
            local perPlayer = {}
            for index, unit in ipairs(list) do
                perPlayer[#perPlayer + 1] = encodeSupplyEntry(index, unit)
            end
            supplyEntries[#supplyEntries + 1] = string.format("%s[%s]", tostring(playerId), table.concat(perPlayer, ","))
        end
        parts[#parts + 1] = "s=" .. table.concat(supplyEntries, ";")

        local buildingEntries = {}
        for _, building in ipairs(state.neutralBuildings or {}) do
            buildingEntries[#buildingEntries + 1] = table.concat({
                tostring(building.row or 0),
                tostring(building.col or 0),
                tostring(building.currentHp or building.startingHp or 0),
                tostring(building.startingHp or 0)
            }, ":")
        end
        table.sort(buildingEntries)
        parts[#parts + 1] = "n=" .. table.concat(buildingEntries, ",")

        local remainingEntries = {}
        for _, unit in ipairs(state.unitsWithRemainingActions or {}) do
            remainingEntries[#remainingEntries + 1] = table.concat({
                tostring(unit.player or 0),
                tostring(unit.name or "?"),
                tostring(unit.row or 0),
                tostring(unit.col or 0)
            }, ":")
        end
        table.sort(remainingEntries)
        parts[#parts + 1] = "r=" .. table.concat(remainingEntries, ",")

        parts[#parts + 1] = "d=" .. boolFlag(state.hasDeployedThisTurn == true)
        parts[#parts + 1] = "a=" .. tostring(state.turnActionCount or 0)
        parts[#parts + 1] = "f=" .. encodeFirstActionRangedAttack(state.firstActionRangedAttack)
        parts[#parts + 1] = "g=" .. encodeGuardAssignments(state.guardAssignments)
        parts[#parts + 1] = "p=" .. tostring(state.currentPlayer or 0)
        parts[#parts + 1] = "t=" .. tostring(state.currentTurn or state.turnNumber or 0)
        parts[#parts + 1] = "phase=" .. tostring(state.phase or "?")

        return table.concat(parts, "|")
    end

    function cacheObj.simulate(ai, state, sequence, playerId, ctxArg)
        local ctxLocal = ctxArg or cacheObj._ctx
        local activePlayer = playerId
        if activePlayer == nil and ai and ai.getFactionId then
            activePlayer = ai:getFactionId()
        end

        local stateSig = stateSignatureWithMemo(cacheObj, ai, state)
        local seqSig = nil
        if ctxLocal and ctxLocal.turnEnumerator and ctxLocal.turnEnumerator.sequenceSignature then
            seqSig = ctxLocal.turnEnumerator.sequenceSignature(sequence or {})
        else
            seqSig = defaultSequenceSignature(sequence or {})
        end

        local key = table.concat({
            stateSig,
            "p=" .. tostring(activePlayer),
            "seq=" .. tostring(seqSig)
        }, "|")

        local cached = cacheObj.simulations[key]
        if cached ~= nil then
            markHit(cacheObj, ctxLocal, "simulation")
            return cached
        end

        markMiss(cacheObj, ctxLocal, "simulation")
        local simulated = nil
        if ai and ai.simulateActionSequenceForPlayer then
            simulated = ai:simulateActionSequenceForPlayer(state, sequence, activePlayer, ctxLocal)
        elseif ai and ai.simulateActionSequence then
            simulated = ai:simulateActionSequence(state, sequence)
        end

        cacheObj.simulations[key] = simulated
        return simulated
    end

    function cacheObj.features(ai, state, playerId, ctxArg)
        local ctxLocal = ctxArg or cacheObj._ctx
        local stateSig = stateSignatureWithMemo(cacheObj, ai, state)
        local key = stateSig .. "|features:" .. tostring(playerId)

        local cached = cacheObj._featureStore[key]
        if cached ~= nil then
            markHit(cacheObj, ctxLocal, "feature")
            return cached
        end

        markMiss(cacheObj, ctxLocal, "feature")

        local built = nil
        if ctxLocal and ctxLocal.evaluator and ctxLocal.evaluator.buildStateFeatures then
            built = ctxLocal.evaluator.buildStateFeatures(ai, state, playerId, ctxLocal)
        elseif ai and ai.buildStateFeatures then
            built = ai:buildStateFeatures(state, playerId, ctxLocal)
        end

        cacheObj._featureStore[key] = built
        return built
    end

    function cacheObj.legalActions(ai, state, playerId, ctxArg, opts)
        local ctxLocal = ctxArg or cacheObj._ctx
        local options = opts or {}

        local stateSig = stateSignatureWithMemo(cacheObj, ai, state)
        local key = table.concat({
            stateSig,
            "legal:" .. tostring(playerId),
            "m=" .. boolFlag(options.includeMove ~= false),
            "a=" .. boolFlag(options.includeAttack ~= false),
            "r=" .. boolFlag(options.includeRepair ~= false),
            "d=" .. boolFlag(options.includeDeploy ~= false),
            "h=" .. boolFlag(options.allowFullHpHealerRepairException == true),
            "u=" .. encodeUsedUnits(options.usedUnits)
        }, "|")

        local cached = cacheObj.legal[key]
        if cached ~= nil then
            markHit(cacheObj, ctxLocal, "legal")
            return cached
        end

        markMiss(cacheObj, ctxLocal, "legal")

        local legal = {}
        if ai and ai.collectLegalActions then
            legal = ai:collectLegalActions(state, {
                aiPlayer = playerId,
                usedUnits = options.usedUnits,
                includeMove = options.includeMove,
                includeAttack = options.includeAttack,
                includeRepair = options.includeRepair,
                includeDeploy = options.includeDeploy,
                allowFullHpHealerRepairException = options.allowFullHpHealerRepairException
            }) or {}
        end

        cacheObj.legal[key] = legal
        return legal
    end

    function cacheObj.supplySnapshot(ai, state, playerId, ctxArg)
        local ctxLocal = ctxArg or cacheObj._ctx
        local stateSig = stateSignatureWithMemo(cacheObj, ai, state)
        local key = stateSig .. "|supply:" .. tostring(playerId)

        local cached = cacheObj.supply[key]
        if cached ~= nil then
            markHit(cacheObj, ctxLocal, "supply")
            return cached
        end

        markMiss(cacheObj, ctxLocal, "supply")

        local snapshot = nil
        if ctxLocal and ctxLocal.reserveModel and ctxLocal.reserveModel.snapshotSupplyForPlayer then
            snapshot = ctxLocal.reserveModel.snapshotSupplyForPlayer(ai, state, playerId, ctxLocal)
        else
            local list = (state and state.supply and state.supply[playerId]) or {}
            local units = {}
            for index, unit in ipairs(list) do
                units[index] = {
                    name = unit.name,
                    currentHp = unit.currentHp,
                    startingHp = unit.startingHp
                }
            end
            snapshot = {
                playerId = playerId,
                count = #units,
                units = units
            }
        end

        cacheObj.supply[key] = snapshot
        return snapshot
    end

    function cacheObj.threat(ai, state, playerToProtect, attackerPlayer, ctxArg)
        local ctxLocal = ctxArg or cacheObj._ctx
        local stateSig = stateSignatureWithMemo(cacheObj, ai, state)
        local key = table.concat({
            stateSig,
            "protect=" .. tostring(playerToProtect),
            "attacker=" .. tostring(attackerPlayer)
        }, "|")

        local cached = cacheObj._threatStore[key]
        if cached ~= nil then
            markHit(cacheObj, ctxLocal, "threat")
            return cached
        end

        markMiss(cacheObj, ctxLocal, "threat")

        local analysis = nil
        if ctxLocal and ctxLocal.threatModel and ctxLocal.threatModel.analyzeHubThreatForPlayer then
            analysis = ctxLocal.threatModel.analyzeHubThreatForPlayer(ai, state, playerToProtect, attackerPlayer, ctxLocal)
        elseif ai and ai.analyzeHubThreatForPlayer then
            analysis = ai:analyzeHubThreatForPlayer(state, playerToProtect, attackerPlayer, ctxLocal)
        end

        cacheObj._threatStore[key] = analysis
        return analysis
    end

    function cacheObj.extension(key, producer)
        local extensionKey = tostring(key or "")
        local cached = cacheObj._extensionStore[extensionKey]
        if cached ~= nil then
            markHit(cacheObj, nil, "extension")
            return cached
        end

        markMiss(cacheObj, nil, "extension")

        local value = nil
        if type(producer) == "function" then
            value = producer()
        else
            value = producer
        end

        cacheObj._extensionStore[extensionKey] = value
        return value
    end

    return cacheObj
end

return M
