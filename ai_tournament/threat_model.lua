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

local function asArray(value)
    if type(value) == "table" then
        return value
    end
    return {}
end

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function cloneUnitRef(unit)
    if type(unit) ~= "table" then
        return nil
    end

    return {
        name = unit.name or unit.unitName or unit.unitType,
        player = unit.player or unit.playerId,
        row = unit.row,
        col = unit.col,
        currentHp = unit.currentHp,
        startingHp = unit.startingHp
    }
end

local function fillUnitRefMissingFields(targetRef, sourceRef)
    if not targetRef or not sourceRef then
        return targetRef
    end

    targetRef.name = targetRef.name or sourceRef.name
    targetRef.player = targetRef.player or sourceRef.player
    targetRef.currentHp = targetRef.currentHp or sourceRef.currentHp
    targetRef.startingHp = targetRef.startingHp or sourceRef.startingHp
    return targetRef
end

local function actionSignature(action)
    if type(action) ~= "table" then
        return "invalid"
    end

    local actionType = tostring(action.type or "unknown")
    if actionType == "supply_deploy" then
        local target = action.target or {}
        local unitName = action.unitName or action.unitType or "?"
        local unitIndex = tonumber(action.unitIndex) or -1
        local row = tonumber(target.row) or -1
        local col = tonumber(target.col) or -1
        return string.format("supply_deploy:%s#%d@%d,%d", tostring(unitName), unitIndex, row, col)
    end

    if actionType == "skip" then
        return "skip"
    end

    local unit = action.unit or {}
    local target = action.target or {}
    return string.format(
        "%s:%d,%d->%d,%d",
        actionType,
        tonumber(unit.row) or -1,
        tonumber(unit.col) or -1,
        tonumber(target.row) or -1,
        tonumber(target.col) or -1
    )
end

local function isInsideBoard(ai, row, col, state)
    if not row or not col then
        return false
    end

    if ai and ai.isInsideBoard then
        return ai:isInsideBoard(row, col, state)
    end

    local boardSize = (state and state.gridSize) or (GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE) or 8
    return row >= 1 and row <= boardSize and col >= 1 and col <= boardSize
end

local function isCellBlocked(ai, state, row, col)
    if not isInsideBoard(ai, row, col, state) then
        return true
    end

    if ai and ai.getUnitAtPosition and ai:getUnitAtPosition(state, row, col) then
        return true
    end

    for _, building in ipairs(asArray(state and state.neutralBuildings)) do
        if building and building.row == row and building.col == col then
            return true
        end
    end

    return false
end

local function getHub(state, playerId)
    if not state or not state.commandHubs then
        return nil
    end
    return state.commandHubs[playerId]
end

local function getHubAsUnit(ai, state, playerId)
    local hub = getHub(state, playerId)
    if not hub then
        return nil
    end

    if ai and ai.getUnitAtPosition then
        local unit = ai:getUnitAtPosition(state, hub.row, hub.col)
        if unit and unit.player == playerId and unit.name == "Commandant" then
            return unit
        end
    end

    return {
        name = "Commandant",
        player = playerId,
        row = hub.row,
        col = hub.col,
        currentHp = hub.currentHp,
        startingHp = hub.startingHp
    }
end

local function isCommandantDead(state, defenderPlayer)
    local hub = getHub(state, defenderPlayer)
    if not hub then
        return true
    end

    local hp = hub.currentHp or hub.startingHp or 0
    if hp <= 0 then
        return true
    end

    return false
end

local function hasAttackTarget(attackCells, targetRow, targetCol)
    for _, cell in ipairs(asArray(attackCells)) do
        if cell and cell.row == targetRow and cell.col == targetCol then
            return true
        end
    end
    return false
end

local function getThreatCache(ctx)
    if type(ctx) ~= "table" then
        return nil
    end

    if type(ctx.threatCache) == "table" then
        return ctx.threatCache
    end

    if type(ctx._threatCache) ~= "table" then
        ctx._threatCache = {}
    end

    return ctx._threatCache
end

local function buildStateSignature(state)
    local parts = {}
    local hubs = {}
    local units = {}
    local supply = {}

    for playerId = 1, 2 do
        local hub = state and state.commandHubs and state.commandHubs[playerId]
        if hub then
            hubs[#hubs + 1] = string.format(
                "%d:%d,%d:%d/%d",
                playerId,
                tonumber(hub.row) or -1,
                tonumber(hub.col) or -1,
                tonumber(hub.currentHp) or -1,
                tonumber(hub.startingHp) or -1
            )
        else
            hubs[#hubs + 1] = string.format("%d:dead", playerId)
        end

        local supplyEntries = {}
        for idx, unit in ipairs(asArray(state and state.supply and state.supply[playerId])) do
            supplyEntries[#supplyEntries + 1] = string.format(
                "%d:%s:%d/%d",
                idx,
                tostring(unit and unit.name or "?"),
                tonumber(unit and unit.currentHp) or -1,
                tonumber(unit and unit.startingHp) or -1
            )
        end
        table.sort(supplyEntries)
        supply[#supply + 1] = string.format("%d[%s]", playerId, table.concat(supplyEntries, ","))
    end

    for _, unit in ipairs(asArray(state and state.units)) do
        units[#units + 1] = string.format(
            "%s:%d:%d,%d:%d/%d:%d:%d:%d",
            tostring(unit and unit.name or "?"),
            tonumber(unit and unit.player) or -1,
            tonumber(unit and unit.row) or -1,
            tonumber(unit and unit.col) or -1,
            tonumber(unit and unit.currentHp) or -1,
            tonumber(unit and unit.startingHp) or -1,
            (unit and unit.hasActed) and 1 or 0,
            (unit and unit.hasMoved) and 1 or 0,
            tonumber(unit and unit.actionsUsed) or -1
        )
    end

    table.sort(hubs)
    table.sort(units)

    parts[#parts + 1] = "hubs=" .. table.concat(hubs, ";")
    parts[#parts + 1] = "units=" .. table.concat(units, ";")
    parts[#parts + 1] = "supply=" .. table.concat(supply, ";")
    parts[#parts + 1] = "deployed=" .. (((state and state.hasDeployedThisTurn) and 1) or 0)
    parts[#parts + 1] = "actionCount=" .. tostring((state and state.turnActionCount) or 0)

    return table.concat(parts, "|")
end

function M.signature(state, playerToProtect, attackerPlayer)
    return table.concat({
        buildStateSignature(state),
        "protect=" .. tostring(playerToProtect),
        "attacker=" .. tostring(attackerPlayer)
    }, "|")
end

local function collectCommandantAttackersFromState(ai, state, attackerPlayer, defenderPlayer)
    local attackers = {}
    local hub = getHub(state, defenderPlayer)
    if not hub then
        return attackers, 0, 0, 0
    end

    local hubUnit = getHubAsUnit(ai, state, defenderPlayer)
    local hubHp = hub.currentHp or hub.startingHp or 0
    local projectedDamage = 0
    local maxSingleDamage = 0
    local lethalCount = 0

    for _, unit in ipairs(asArray(state and state.units)) do
        if unit
            and unit.player == attackerPlayer
            and not (ai and ai.isHubUnit and ai:isHubUnit(unit))
            and not (ai and ai.isObstacleUnit and ai:isObstacleUnit(unit)) then
            local attackCells = ai and ai.getValidAttackCells and ai:getValidAttackCells(state, unit.row, unit.col) or {}
            if hasAttackTarget(attackCells, hub.row, hub.col) then
                local damage = 0
                if ai and ai.calculateDamage then
                    damage = ai:calculateDamage(unit, hubUnit)
                end
                local distance = math.abs((unit.row or 0) - (hub.row or 0)) + math.abs((unit.col or 0) - (hub.col or 0))
                projectedDamage = projectedDamage + damage
                maxSingleDamage = math.max(maxSingleDamage, damage)
                if damage >= hubHp then
                    lethalCount = lethalCount + 1
                end

                attackers[#attackers + 1] = {
                    unit = cloneUnitRef(unit),
                    damage = damage,
                    distance = distance,
                    attackType = "direct"
                }
            end
        end
    end

    table.sort(attackers, function(a, b)
        if (a.damage or 0) ~= (b.damage or 0) then
            return (a.damage or 0) > (b.damage or 0)
        end
        if (a.distance or 0) ~= (b.distance or 0) then
            return (a.distance or 0) < (b.distance or 0)
        end

        local unitA = a.unit or {}
        local unitB = b.unit or {}
        local sigA = string.format("%s:%d,%d", tostring(unitA.name or "?"), tonumber(unitA.row) or -1, tonumber(unitA.col) or -1)
        local sigB = string.format("%s:%d,%d", tostring(unitB.name or "?"), tonumber(unitB.row) or -1, tonumber(unitB.col) or -1)
        return sigA < sigB
    end)

    return attackers, projectedDamage, maxSingleDamage, lethalCount
end

local function resolveAttackRange(ai, unit)
    if not unit then
        return 1
    end

    local attackRange = num(unit.atkRange or unit.range, nil)
    if attackRange then
        return attackRange
    end

    if ai and ai.unitsInfo and ai.unitsInfo.getUnitAttackRange then
        local ok, resolved = pcall(ai.unitsInfo.getUnitAttackRange, ai.unitsInfo, unit, "TOURNAMENT_THREAT_BLOCK_RANGE")
        if ok and resolved then
            return num(resolved, 1)
        end
    end

    if ai and ai.unitHasTag and ai:unitHasTag(unit, "ranged") then
        return 2
    end

    return 1
end

function M.findCommandantAttackers(ai, state, attackerPlayer, defenderPlayer, ctx)
    if not ai or not state or not attackerPlayer or not defenderPlayer then
        return {}
    end

    local prepared = ai:prepareStateForPlayerTurn(state, attackerPlayer, {
        resetActionCount = true,
        resetDeployment = true,
        resetFirstActionRangedAttack = true
    })

    local attackers = collectCommandantAttackersFromState(ai, prepared, attackerPlayer, defenderPlayer)
    return attackers
end

local function collectLegalActionsForPlayer(ai, state, playerId, ctx)
    local actions = {}

    local legalOpts = {
        includeMove = true,
        includeAttack = true,
        includeRepair = true,
        includeDeploy = false
    }
    local nonDeploy = nil
    if ctx and ctx.cache and ctx.cache.legalActions then
        nonDeploy = ctx.cache.legalActions(ai, state, playerId, ctx, legalOpts)
    elseif ai and ai.collectLegalActions then
        nonDeploy = ai:collectLegalActions(state, {
            aiPlayer = playerId,
            includeMove = true,
            includeAttack = true,
            includeRepair = true,
            includeDeploy = false
        })
    end
    nonDeploy = nonDeploy or {}

    for _, entry in ipairs(nonDeploy) do
        if entry and entry.action then
            actions[#actions + 1] = entry.action
        end
    end

    local deployments = {}
    if ai.getPossibleSupplyDeploymentsForPlayer then
        deployments = ai:getPossibleSupplyDeploymentsForPlayer(state, playerId, true, {
            scoreDeployments = false
        }) or {}
    elseif ai.getPossibleSupplyDeployments then
        deployments = ai:getPossibleSupplyDeployments(state, true) or {}
    end

    for _, deployment in ipairs(deployments) do
        if deployment then
            actions[#actions + 1] = deployment
        end
    end

    return actions
end

local function applyActionForPlayer(ai, state, action, playerId)
    if not ai or not state or not action then
        return nil
    end

    if action.type == "supply_deploy" then
        if ai.applySupplyDeploymentForPlayer then
            return ai:applySupplyDeploymentForPlayer(state, action, playerId, {
                scoreDeployments = false
            })
        end
        if ai.applySupplyDeployment then
            return ai:applySupplyDeployment(state, action)
        end
        return nil
    end

    if action.type ~= "skip" and ai.applyMove then
        return ai:applyMove(state, action)
    end

    return state
end

local function unitKey(unit)
    if type(unit) ~= "table" then
        return ""
    end

    return table.concat({
        tostring(unit.player or "?"),
        tostring(unit.name or "?"),
        tostring(unit.row or "?"),
        tostring(unit.col or "?")
    }, ":")
end

local sortActions

local function collectMoveAttackCommandantPressures(ai, state, attackerPlayer, defenderPlayer, ctx)
    local attackers = {}
    local hub = getHub(state, defenderPlayer)
    if not hub then
        return attackers, 0, 0
    end

    local hubUnit = getHubAsUnit(ai, state, defenderPlayer)
    local prepared = ai:prepareStateForPlayerTurn(state, attackerPlayer, {
        resetActionCount = true,
        resetDeployment = true,
        resetFirstActionRangedAttack = true
    })

    local firstActions = collectLegalActionsForPlayer(ai, prepared, attackerPlayer, ctx)
    sortActions(firstActions, hub)

    local cfg = (ctx and ctx.cfg) or (ai.getTournamentConfig and ai:getTournamentConfig()) or {}
    local maxFirst = math.max(1, tonumber(cfg.MAX_FIRST_ACTIONS) or 72)
    local maxSingleDamage = 0
    local projectedDamage = 0
    local seen = {}

    local scanned = 0
    for _, firstAction in ipairs(firstActions) do
        if ctx and ctx.shouldStop and ctx.shouldStop() then
            break
        end
        if firstAction and firstAction.type == "move" then
            scanned = scanned + 1
            if scanned > maxFirst then
                break
            end

            local originalUnit = firstAction.unit
            local afterMove = applyActionForPlayer(ai, prepared, firstAction, attackerPlayer)
            local movedUnit = afterMove
                and ai.getUnitAtPosition
                and ai:getUnitAtPosition(afterMove, firstAction.target.row, firstAction.target.col)
            if movedUnit
                and movedUnit.player == attackerPlayer
                and not (ai.isHubUnit and ai:isHubUnit(movedUnit))
                and not (ai.isObstacleUnit and ai:isObstacleUnit(movedUnit)) then
                local attackCells = ai.getValidAttackCells
                    and ai:getValidAttackCells(afterMove, movedUnit.row, movedUnit.col)
                    or {}
                if hasAttackTarget(attackCells, hub.row, hub.col) then
                    local damage = 0
                    if ai.calculateDamage then
                        damage = ai:calculateDamage(movedUnit, hubUnit)
                    end
                    if damage > 0 then
                        local key = unitKey(originalUnit)
                        local existing = seen[key]
                        local attackAction = {
                            type = "attack",
                            unit = cloneUnitRef(movedUnit),
                            target = {
                                row = hub.row,
                                col = hub.col
                            }
                        }
                        local distance = math.abs((movedUnit.row or 0) - (hub.row or 0))
                            + math.abs((movedUnit.col or 0) - (hub.col or 0))
                        local projectedRef = cloneUnitRef(movedUnit)
                        local originalRef = fillUnitRefMissingFields(cloneUnitRef(originalUnit), projectedRef)
                        local entry = {
                            unit = originalRef,
                            projectedUnit = projectedRef,
                            damage = damage,
                            distance = distance,
                            attackType = "move_attack",
                            sequenceSignature = {
                                actionSignature(firstAction),
                                actionSignature(attackAction)
                            }
                        }
                        if not existing or damage > (existing.damage or 0) then
                            seen[key] = entry
                        end
                    end
                end
            end
        end
    end

    for _, entry in pairs(seen) do
        attackers[#attackers + 1] = entry
        projectedDamage = math.max(projectedDamage, entry.damage or 0)
        maxSingleDamage = math.max(maxSingleDamage, entry.damage or 0)
    end

    table.sort(attackers, function(a, b)
        if (a.damage or 0) ~= (b.damage or 0) then
            return (a.damage or 0) > (b.damage or 0)
        end
        if (a.distance or 0) ~= (b.distance or 0) then
            return (a.distance or 0) < (b.distance or 0)
        end
        local unitA = a.unit or {}
        local unitB = b.unit or {}
        local sigA = string.format("%s:%d,%d", tostring(unitA.name or "?"), tonumber(unitA.row) or -1, tonumber(unitA.col) or -1)
        local sigB = string.format("%s:%d,%d", tostring(unitB.name or "?"), tonumber(unitB.row) or -1, tonumber(unitB.col) or -1)
        return sigA < sigB
    end)

    return attackers, projectedDamage, maxSingleDamage
end

local function actionPriority(action, defenderHub)
    local actionType = action and action.type
    if actionType == "attack" then
        local target = action.target or {}
        if defenderHub and target.row == defenderHub.row and target.col == defenderHub.col then
            return 0
        end
        return 1
    end
    if actionType == "move" then
        return 2
    end
    if actionType == "repair" then
        return 3
    end
    if actionType == "supply_deploy" then
        return 4
    end
    if actionType == "skip" then
        return 5
    end
    return 6
end

function sortActions(actions, defenderHub)
    table.sort(actions, function(a, b)
        local pa = actionPriority(a, defenderHub)
        local pb = actionPriority(b, defenderHub)
        if pa ~= pb then
            return pa < pb
        end
        return actionSignature(a) < actionSignature(b)
    end)
end

local function detectImmediateLethalBySearch(ai, state, attackerPlayer, defenderPlayer, ctx)
    local cfg = (ctx and ctx.cfg) or (ai.getTournamentConfig and ai:getTournamentConfig()) or {}
    local turnCfg = ((ai.AI_PARAMS or {}).RULE_CONTRACT or {}).TURN or {}
    local maxActions = math.max(1, tonumber(turnCfg.ACTIONS_PER_TURN) or 2)
    local maxFirst = math.max(1, tonumber(cfg.MAX_FIRST_ACTIONS) or 72)
    local maxSecond = math.max(1, tonumber(cfg.MAX_SECOND_ACTIONS) or 36)

    local winningSequence = nil

    local function dfs(currentState, depth, sequence)
        if ctx and ctx.shouldStop and ctx.shouldStop() then
            return false
        end

        if not currentState then
            return false
        end

        if isCommandantDead(currentState, defenderPlayer) then
            winningSequence = deepCopy(sequence)
            return true
        end

        if depth >= maxActions then
            return false
        end

        local defenderHub = getHub(currentState, defenderPlayer)
        local actions = collectLegalActionsForPlayer(ai, currentState, attackerPlayer, ctx)
        sortActions(actions, defenderHub)

        local maxActionsAtDepth = depth == 0 and maxFirst or maxSecond
        if #actions > maxActionsAtDepth then
            for idx = #actions, maxActionsAtDepth + 1, -1 do
                actions[idx] = nil
            end
        end

        for _, action in ipairs(actions) do
            if ctx and ctx.shouldStop and ctx.shouldStop() then
                return false
            end

            local nextState = nil
            if action and action.type == "supply_deploy" then
                nextState = ai:applySupplyDeploymentForPlayer(currentState, action, attackerPlayer, {
                    scoreDeployments = false
                })
            elseif action and action.type ~= "skip" then
                nextState = ai:applyMove(currentState, action)
            end

            if nextState then
                sequence[#sequence + 1] = action
                if isCommandantDead(nextState, defenderPlayer) then
                    winningSequence = deepCopy(sequence)
                    return true
                end
                if dfs(nextState, depth + 1, sequence) then
                    return true
                end
                sequence[#sequence] = nil
            end
        end

        return false
    end

    local ok = dfs(state, 0, {})
    return ok == true, winningSequence
end

function M.hasImmediateCommandantLethal(ai, state, attackerPlayer, defenderPlayer, ctx)
    if not ai or not state or not attackerPlayer or not defenderPlayer then
        return false, nil
    end

    local cache = getThreatCache(ctx)
    local cacheKey = "lethal|" .. M.signature(state, defenderPlayer, attackerPlayer)
    if cache and cache[cacheKey] ~= nil then
        local cached = cache[cacheKey]
        return cached.value == true, deepCopy(cached.sequence)
    end

    local prepared = ai:prepareStateForPlayerTurn(state, attackerPlayer, {
        resetActionCount = true,
        resetDeployment = true,
        resetFirstActionRangedAttack = true
    })

    local lethal, sequence = detectImmediateLethalBySearch(ai, prepared, attackerPlayer, defenderPlayer, ctx)

    if cache then
        cache[cacheKey] = {
            value = lethal == true,
            sequence = deepCopy(sequence)
        }
    end

    return lethal == true, sequence
end

function M.findBlockCells(ai, state, attackerPlayer, defenderPlayer, threat, ctx)
    local _ = ctx
    local hub = getHub(state, defenderPlayer)
    if not hub then
        return {}
    end

    local cellsByKey = {}
    local cells = {}

    local function addCell(row, col)
        if not row or not col then
            return
        end
        if not isInsideBoard(ai, row, col, state) then
            return
        end
        local key = string.format("%d,%d", row, col)
        if cellsByKey[key] then
            return
        end
        cellsByKey[key] = true
        cells[#cells + 1] = {row = row, col = col}
    end

    -- Minimum fallback: free cells around Commandant where deploy/move can body-block.
    for _, dir in ipairs(ai:getOrthogonalDirections() or {}) do
        local row = hub.row + dir.row
        local col = hub.col + dir.col
        if not isCellBlocked(ai, state, row, col) then
            addCell(row, col)
        end
    end

    local threatData = threat
    if type(threatData) ~= "table" then
        local synthetic = M.analyzeHubThreatForPlayer(ai, state, defenderPlayer, attackerPlayer, ctx)
        threatData = synthetic
    end

    for _, entry in ipairs(asArray(threatData and threatData.damagingAttackers)) do
        local attacker = entry and entry.unit
        if attacker then
            local attackRange = resolveAttackRange(ai, attacker)
            local usedLineBlock = false
            if attackRange >= 2 and ai and ai.getLinePath then
                local path = ai:getLinePath(
                    {row = attacker.row, col = attacker.col},
                    {row = hub.row, col = hub.col}
                ) or {}

                if #path >= 2 then
                    usedLineBlock = true
                    for idx = 2, #path - 1 do
                        local pos = path[idx]
                        if pos and not isCellBlocked(ai, state, pos.row, pos.col) then
                            addCell(pos.row, pos.col)
                        end
                    end
                end
            end

            if not usedLineBlock then
                -- Melee/body-block threat shape: include attacker occupied pressure cell.
                addCell(attacker.row, attacker.col)
            end
        end
    end

    table.sort(cells, function(a, b)
        if a.row ~= b.row then
            return a.row < b.row
        end
        return a.col < b.col
    end)

    return cells
end

function M.findEscapeCells(ai, state, defenderPlayer, threat, ctx)
    local _ = threat
    local _ctx = ctx
    local hub = getHub(state, defenderPlayer)
    if not hub then
        return {}
    end

    local cells = {}
    for _, dir in ipairs(ai:getOrthogonalDirections() or {}) do
        local row = hub.row + dir.row
        local col = hub.col + dir.col
        if not isCellBlocked(ai, state, row, col) then
            cells[#cells + 1] = {row = row, col = col}
        end
    end

    table.sort(cells, function(a, b)
        if a.row ~= b.row then
            return a.row < b.row
        end
        return a.col < b.col
    end)

    return cells
end

function M.analyzeHubThreatForPlayer(ai, state, playerToProtect, attackerPlayer, ctx)
    local result = {
        playerToProtect = playerToProtect,
        attackerPlayer = attackerPlayer,
        hub = nil,
        immediateDanger = false,
        immediateLethal = false,
        projectedDamage = 0,
        maxSingleDamage = 0,
        damagingAttackers = {},
        lethalAttackers = {},
        blockCells = {},
        escapeCells = {},
        reasons = {}
    }

    if not ai or not state or not playerToProtect or not attackerPlayer then
        result.reasons[#result.reasons + 1] = "invalid_arguments"
        return result
    end

    local cache = getThreatCache(ctx)
    local cacheKey = M.signature(state, playerToProtect, attackerPlayer)
    if cache and cache[cacheKey] ~= nil then
        return deepCopy(cache[cacheKey])
    end

    local hub = getHub(state, playerToProtect)
    if not hub then
        result.reasons[#result.reasons + 1] = "missing_hub"
        if cache then
            cache[cacheKey] = deepCopy(result)
        end
        return result
    end

    result.hub = {
        row = hub.row,
        col = hub.col,
        currentHp = hub.currentHp,
        startingHp = hub.startingHp
    }

    local prepared = ai:prepareStateForPlayerTurn(state, attackerPlayer, {
        resetActionCount = true,
        resetDeployment = true,
        resetFirstActionRangedAttack = true
    })

    local damagingAttackers, projectedDamage, maxSingleDamage, _ =
        collectCommandantAttackersFromState(ai, prepared, attackerPlayer, playerToProtect)

    local moveAttackPressure = false
    local moveAttackSequenceSignature = nil
    if #damagingAttackers == 0 then
        local moveAttackAttackers, moveAttackDamage, moveAttackMaxDamage =
            collectMoveAttackCommandantPressures(ai, prepared, attackerPlayer, playerToProtect, ctx)
        if #moveAttackAttackers > 0 and (moveAttackDamage or 0) > 0 then
            damagingAttackers = moveAttackAttackers
            projectedDamage = moveAttackDamage or 0
            maxSingleDamage = moveAttackMaxDamage or projectedDamage or 0
            moveAttackPressure = true
            moveAttackSequenceSignature = moveAttackAttackers[1] and moveAttackAttackers[1].sequenceSignature or nil
        end
    end

    result.damagingAttackers = damagingAttackers
    result.projectedDamage = projectedDamage or 0
    result.maxSingleDamage = maxSingleDamage or 0
    result.immediateDanger = #damagingAttackers > 0
    result.fullTurnPressure = moveAttackPressure == true
    result.fullTurnPressureSequenceSignature = moveAttackSequenceSignature

    local hubHp = hub.currentHp or hub.startingHp or 0
    for _, attacker in ipairs(damagingAttackers) do
        if (attacker.damage or 0) >= hubHp then
            result.lethalAttackers[#result.lethalAttackers + 1] = deepCopy(attacker)
        end
    end

    local immediateLethal, lethalSequence = M.hasImmediateCommandantLethal(ai, state, attackerPlayer, playerToProtect, ctx)
    result.immediateLethal = immediateLethal == true

    if result.immediateDanger and not result.fullTurnPressure then
        result.reasons[#result.reasons + 1] = "direct_attackers_detected"
    end
    if result.fullTurnPressure then
        result.reasons[#result.reasons + 1] = "move_attack_pressure_detected"
    end
    if result.immediateLethal then
        result.reasons[#result.reasons + 1] = "full_turn_lethal"
        if lethalSequence and #lethalSequence > 0 then
            result.lethalSequenceSignature = {}
            for idx, action in ipairs(lethalSequence) do
                result.lethalSequenceSignature[idx] = actionSignature(action)
            end
        end
    end

    result.blockCells = M.findBlockCells(ai, prepared, attackerPlayer, playerToProtect, result, ctx)
    result.escapeCells = M.findEscapeCells(ai, prepared, playerToProtect, result, ctx)

    if cache then
        cache[cacheKey] = deepCopy(result)
    end

    return result
end

return M
