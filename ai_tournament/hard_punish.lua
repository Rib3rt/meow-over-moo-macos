local M = {}

local punishMap = require("ai_tournament.punish_map")

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function cloneValue(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[key] = cloneValue(child)
    end
    return out
end

local function actionTargetText(action)
    local target = action and action.target or nil
    if not target then
        return nil
    end
    return string.format("%s,%s", tostring(target.row or "?"), tostring(target.col or "?"))
end

local function unitText(unit)
    if not unit then
        return nil
    end
    return string.format(
        "%s@%s,%s",
        tostring(unit.name or "unit"),
        tostring(unit.row or "?"),
        tostring(unit.col or "?")
    )
end

local function cellKey(cell)
    return tostring(cell and cell.row or "?") .. "," .. tostring(cell and cell.col or "?")
end

local function isRangedCommandantPokeUnit(unit)
    local name = tostring(unit and unit.name or "")
    return name == "Cloudstriker" or name == "Artillery"
end

local function getOpponent(playerId)
    return playerId == 1 and 2 or 1
end

local function getEnemyHub(state, ctx)
    local enemyPlayer = ctx and ctx.enemyPlayer or getOpponent(ctx and ctx.aiPlayer or 1)
    local hub = state and state.commandHubs and state.commandHubs[enemyPlayer] or nil
    if not hub then
        return nil
    end
    return {
        name = "Commandant",
        player = enemyPlayer,
        row = hub.row,
        col = hub.col,
        currentHp = hub.currentHp,
        startingHp = hub.startingHp
    }
end

local function getUnitAt(ai, state, row, col)
    local priv = punishMap and punishMap._private or {}
    if priv.getUnitAt then
        return priv.getUnitAt(ai, state, row, col, true)
    end
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.row == row and unit.col == col then
            return unit
        end
    end
    return nil
end

local function actionUnit(ai, state, action, entry)
    local unit = entry and entry.unit or nil
    if unit and unit.name then
        return unit
    end
    local source = action and action.unit or nil
    if source then
        return getUnitAt(ai, state, source.row, source.col)
    end
    return nil
end

local function targetIsEnemyHub(action, enemyHub)
    return action
        and action.target
        and enemyHub
        and num(action.target.row, 0) == num(enemyHub.row, 0)
        and num(action.target.col, 0) == num(enemyHub.col, 0)
end

local function calculateDamage(ai, attacker, target)
    local priv = punishMap and punishMap._private or {}
    if priv.calculateDamage then
        return priv.calculateDamage(ai, attacker, target)
    end
    return num(attacker and attacker.atkDamage, 0)
end

local function simulate(ai, state, ctx, actions)
    if ctx and ctx.cache and ctx.cache.simulate then
        return ctx.cache.simulate(ai, state, actions, ctx.aiPlayer, ctx)
    end
    if ai and ai.simulateActionSequenceForPlayer then
        return ai:simulateActionSequenceForPlayer(state, actions, ctx and ctx.aiPlayer or 1, {})
    end
    return nil
end

local function attackerAfterSequence(ai, afterState, action)
    local source = action and action.unit or nil
    if not (afterState and source) then
        return nil
    end
    return getUnitAt(ai, afterState, source.row, source.col)
end

local function hasEnemyCounter(ai, afterState, ctx, attacker)
    if not (punishMap and punishMap.bestEnemyReply and afterState and attacker) then
        return true
    end
    local reply = punishMap.bestEnemyReply(
        afterState,
        ai,
        ctx,
        ctx and ctx.aiPlayer or attacker.player,
        attacker,
        attacker
    )
    return reply ~= nil, reply
end

local function isDefensePressure(contracts)
    return contracts
        and contracts.defenseActive == true
        and contracts.defenseKind == "pressure"
end

local function threatPayload(threatResult)
    if not threatResult then
        return nil
    end
    return threatResult.threat or threatResult
end

local function threatProjectedDamage(threatResult)
    local threat = threatPayload(threatResult)
    return num((threatResult and threatResult.projectedDamage) or (threat and threat.projectedDamage), 0)
end

local function threatAttackerCount(threatResult)
    local threat = threatPayload(threatResult)
    return #((threatResult and threatResult.damagingAttackers) or (threat and threat.damagingAttackers) or {})
end

local function threatHasImmediateDanger(threatResult)
    local threat = threatPayload(threatResult)
    return (threatResult and threatResult.immediateDanger == true)
        or (threat and threat.immediateDanger == true)
        or threatProjectedDamage(threatResult) > 0
        or threatAttackerCount(threatResult) > 0
end

local function coordKey(row, col)
    local r = tonumber(row)
    local c = tonumber(col)
    if not (r and c) then
        return nil
    end
    return tostring(math.floor(r)) .. "," .. tostring(math.floor(c))
end

local function addThreatCell(cells, unit)
    local key = coordKey(unit and unit.row, unit and unit.col)
    if key then
        cells[key] = true
    end
end

local function threatAttackerCells(threatResult)
    local threat = threatPayload(threatResult)
    local cells = {}
    for _, entry in ipairs((threatResult and threatResult.damagingAttackers) or (threat and threat.damagingAttackers) or {}) do
        addThreatCell(cells, entry and entry.unit)
        addThreatCell(cells, entry and entry.attacker)
        addThreatCell(cells, entry and entry.source)
        local directKey = coordKey(entry and entry.row, entry and entry.col)
        if directKey then
            cells[directKey] = true
        end
    end
    return cells
end

local function selectionTargetsThreatUnit(selection, threatResult)
    if not selection then
        return false
    end
    local cells = threatAttackerCells(threatResult)
    for _, action in ipairs(selection.actions or {}) do
        if action and action.type == "attack" and action.target then
            local key = coordKey(action.target.row, action.target.col)
            if key and cells[key] then
                return true
            end
        end
    end
    return false
end

local function analyzeDefenseThreat(ai, state, ctx)
    if not (ctx and ctx.threatModel and ctx.threatModel.analyzeHubThreatForPlayer) then
        return nil
    end
    return ctx.threatModel.analyzeHubThreatForPlayer(ai, state, ctx.aiPlayer, ctx.enemyPlayer, ctx)
end

local function selectionReducesDefensePressure(ai, state, ctx, contracts, selection)
    if not (selection and selection.actions and #selection.actions > 0) then
        return false, "missing_selection_actions"
    end
    local beforeThreat = contracts and contracts.defenseThreat or nil
    local afterState = simulate(ai, state, ctx, selection.actions)
    if not afterState then
        return false, "simulation_failed"
    end
    local afterThreat = analyzeDefenseThreat(ai, afterState, ctx)
    local beforeProjected = threatProjectedDamage(beforeThreat)
    local beforeCount = threatAttackerCount(beforeThreat)
    local afterProjected = threatProjectedDamage(afterThreat)
    local afterCount = threatAttackerCount(afterThreat)

    if not threatHasImmediateDanger(afterThreat) then
        return true, "pressure_cleared"
    end
    if afterProjected < beforeProjected then
        return true, "projected_pressure_reduced"
    end
    if afterCount < beforeCount then
        return true, "pressure_attacker_reduced"
    end

    return false, "pressure_not_reduced"
end

local function allowSelectionForDefensePressure(ai, state, ctx, contracts, selection)
    if not isDefensePressure(contracts) then
        return true, nil
    end
    if selection.kind == "ranged_commandant_pressure"
        or selection.kind == "move_ranged_commandant_pressure" then
        return false, "defense_pressure_requires_safe_kill"
    end
    if selectionTargetsThreatUnit(selection, contracts.defenseThreat) then
        return true, "targets_pressure_source"
    end
    return selectionReducesDefensePressure(ai, state, ctx, contracts, selection)
end

local function markDefensePressureSelection(selection, proof)
    selection.defensePressureResolved = true
    selection.defensePressureProof = proof or "defend_now_safe_kill"
    selection.reason = "hard_punish_defend_now_safe_kill"
    selection.proof = "defend_now_safe_kill"
    return selection
end

local function shouldRun(ai, state, ctx, contracts)
    if not (ai and state and ctx and ctx.cfg) then
        return false, "missing_context"
    end
    local enabled = ctx.cfg.HARD_PUNISH_ENABLED
    if enabled == nil then
        enabled = ctx.cfg.EARLY_HARD_PUNISH_ENABLED
    end
    if enabled == false then
        return false, "disabled"
    end
    if contracts and contracts.defenseActive == true and not isDefensePressure(contracts) then
        return false, "hard_defense_contract"
    end
    if not (ai.findSafeKillAttacks and ai.findSafeMoveAttackKills) then
        return false, "hard_safe_kill_tools_unavailable"
    end
    return true, nil
end

local function directCandidates(ai, state)
    return ai:findSafeKillAttacks(state, {}) or {}
end

local function moveAttackCandidates(ai, state)
    return ai:findSafeMoveAttackKills(state, {}) or {}
end

local function twoUnitCandidates(ai, state)
    if not (ai and ai.findTwoUnitKillCombinations) then
        return {}
    end
    return ai:findTwoUnitKillCombinations(state, {}, true) or {}
end

local function cloudstrikerLosCandidates(ai, state)
    if not (ai and ai.findCorvetteLineOfSightKills) then
        return {}
    end
    return ai:findCorvetteLineOfSightKills(state, {}) or {}
end

local function collectAttackEntries(ai, state, ctx)
    if not (ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions) then
        return {}
    end
    return ctx.turnEnumerator.collectTournamentActions(ai, state, ctx.aiPlayer, ctx, {
        includeMove = false,
        includeAttack = true,
        includeRepair = false,
        includeDeploy = false
    }) or {}
end

local function collectMoveEntries(ai, state, ctx)
    if not (ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions) then
        return {}
    end
    return ctx.turnEnumerator.collectTournamentActions(ai, state, ctx.aiPlayer, ctx, {
        includeMove = true,
        includeAttack = false,
        includeRepair = false,
        includeDeploy = false
    }) or {}
end

local function rangedCommandantPressureSort(a, b)
    if num(a and a.damage, 0) ~= num(b and b.damage, 0) then
        return num(a and a.damage, 0) > num(b and b.damage, 0)
    end
    if #(a and a.actions or {}) ~= #(b and b.actions or {}) then
        return #(a and a.actions or {}) < #(b and b.actions or {})
    end
    return tostring(a and a.signature or "") < tostring(b and b.signature or "")
end

local function rangedCommandantPressureCandidate(ai, state, ctx)
    if not (ctx and ctx.cfg and ctx.cfg.EARLY_HARD_RANGED_COMMANDANT_PRESSURE_ENABLED ~= false) then
        return nil, 0
    end

    local enemyHub = getEnemyHub(state, ctx)
    if not enemyHub then
        return nil, 0
    end

    local candidates = {}
    local seen = {}
    local function pushCandidate(actions, unit, damage, moved)
        local signatureParts = {}
        for _, action in ipairs(actions or {}) do
            signatureParts[#signatureParts + 1] = string.format(
                "%s:%s>%s",
                tostring(action.type or "?"),
                cellKey(action.unit),
                cellKey(action.target)
            )
        end
        local signature = table.concat(signatureParts, "|")
        if seen[signature] then
            return
        end
        seen[signature] = true
        candidates[#candidates + 1] = {
            actions = cloneValue(actions),
            unit = unit,
            targetName = "Commandant",
            target = cloneValue(enemyHub),
            damage = damage,
            value = damage * 100,
            moved = moved == true,
            signature = signature
        }
    end

    for _, entry in ipairs(collectAttackEntries(ai, state, ctx)) do
        local action = entry and entry.action or nil
        local unit = actionUnit(ai, state, action, entry)
        if action
            and action.type == "attack"
            and isRangedCommandantPokeUnit(unit)
            and targetIsEnemyHub(action, enemyHub) then
            local damage = calculateDamage(ai, unit, enemyHub)
            if damage > 0 then
                local afterAttack = simulate(ai, state, ctx, {action})
                local attacker = attackerAfterSequence(ai, afterAttack, action)
                local counter = hasEnemyCounter(ai, afterAttack, ctx, attacker)
                if afterAttack and attacker and not counter then
                    pushCandidate({action}, unit, damage, false)
                end
            end
        end
    end

    if ctx.cfg.EARLY_HARD_RANGED_COMMANDANT_PRESSURE_MOVE_ATTACK_ENABLED ~= false then
        local moveScanCap = math.max(0, num(ctx.cfg.EARLY_HARD_RANGED_COMMANDANT_PRESSURE_MOVE_SCAN_CAP, 24))
        local scanned = 0
        for _, moveEntry in ipairs(collectMoveEntries(ai, state, ctx)) do
            if scanned >= moveScanCap then
                break
            end
            local move = moveEntry and moveEntry.action or nil
            local unit = actionUnit(ai, state, move, moveEntry)
            if move and move.type == "move" and isRangedCommandantPokeUnit(unit) then
                scanned = scanned + 1
                local afterMove = simulate(ai, state, ctx, {move})
                if afterMove then
                    for _, attackEntry in ipairs(collectAttackEntries(ai, afterMove, ctx)) do
                        local attack = attackEntry and attackEntry.action or nil
                        local movedUnit = actionUnit(ai, afterMove, attack, attackEntry)
                        if attack
                            and attack.type == "attack"
                            and isRangedCommandantPokeUnit(movedUnit)
                            and targetIsEnemyHub(attack, enemyHub) then
                            local damage = calculateDamage(ai, movedUnit, enemyHub)
                            if damage > 0 then
                                local afterAttack = simulate(ai, afterMove, ctx, {attack})
                                local attacker = attackerAfterSequence(ai, afterAttack, attack)
                                local counter = hasEnemyCounter(ai, afterAttack, ctx, attacker)
                                if afterAttack and attacker and not counter then
                                    pushCandidate({move, attack}, movedUnit, damage, true)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, rangedCommandantPressureSort)
    return candidates[1], #candidates
end

local function buildDirect(entry)
    if not (entry and entry.action and entry.unit) then
        return nil
    end

    return {
        kind = "direct_safe_kill",
        reason = "hard_punish_safe_kill",
        actions = {cloneValue(entry.action)},
        unit = entry.unit,
        targetName = entry.targetName,
        target = entry.action.target and cloneValue(entry.action.target) or nil,
        damage = num(entry.damage, 0),
        value = num(entry.value, 0),
        proof = "safe_kill"
    }
end

local function buildMoveAttack(entry)
    if not (entry and entry.moveAction and entry.attackAction and entry.unit) then
        return nil
    end

    return {
        kind = "move_attack_safe_kill",
        reason = "hard_punish_safe_move_attack_kill",
        actions = {cloneValue(entry.moveAction), cloneValue(entry.attackAction)},
        unit = entry.unit,
        targetName = entry.targetName,
        target = entry.attackAction.target and cloneValue(entry.attackAction.target) or nil,
        moveTarget = entry.moveAction.target and cloneValue(entry.moveAction.target) or nil,
        damage = num(entry.damage, 0),
        value = num(entry.value, 0),
        safetyScore = num(entry.safetyScore, 0),
        proof = "safe_move_attack_kill"
    }
end

local function buildTwoUnit(entry)
    if not (entry and entry.damageAction and entry.killAction and entry.damager and entry.killer) then
        return nil
    end

    return {
        kind = "two_unit_safe_kill",
        reason = "hard_punish_two_unit_safe_kill",
        actions = {cloneValue(entry.damageAction), cloneValue(entry.killAction)},
        unit = entry.damager,
        secondUnit = entry.killer,
        targetName = entry.target and entry.target.name or nil,
        target = entry.killAction.target and cloneValue(entry.killAction.target) or nil,
        damage = num(entry.totalDamage, 0),
        value = num(entry.value, 0),
        proof = "two_unit_safe_kill"
    }
end

local function buildCloudstrikerLos(entry)
    if not (entry and entry.moveAction and entry.attackAction and entry.mover and entry.corvette) then
        return nil
    end

    return {
        kind = "cloudstriker_los_safe_kill",
        reason = "hard_punish_cloudstriker_los_safe_kill",
        actions = {cloneValue(entry.moveAction), cloneValue(entry.attackAction)},
        unit = entry.mover,
        secondUnit = entry.corvette,
        targetName = entry.target and entry.target.name or nil,
        target = entry.attackAction.target and cloneValue(entry.attackAction.target) or nil,
        moveTarget = entry.moveAction.target and cloneValue(entry.moveAction.target) or nil,
        damage = num(entry.damage, 0),
        value = num(entry.value, 0),
        benefit = num(entry.benefit, 0),
        proof = "cloudstriker_los_safe_kill"
    }
end

local function buildRangedCommandantPressure(entry)
    if not (entry and entry.actions and entry.unit and entry.target) then
        return nil
    end
    local moved = entry.moved == true
    return {
        kind = moved and "move_ranged_commandant_pressure" or "ranged_commandant_pressure",
        reason = moved
            and "hard_punish_move_ranged_commandant_pressure"
            or "hard_punish_ranged_commandant_pressure",
        actions = cloneValue(entry.actions),
        unit = entry.unit,
        targetName = "Commandant",
        target = cloneValue(entry.target),
        damage = num(entry.damage, 0),
        value = num(entry.value, 0),
        proof = moved and "safe_move_ranged_commandant_pressure" or "safe_ranged_commandant_pressure"
    }
end

function M.select(ai, state, ctx, contracts)
    local stats = ctx and ctx.stats or {}
    local cfg = ctx and ctx.cfg or {}
    local enabled = cfg.HARD_PUNISH_ENABLED
    if enabled == nil then
        enabled = cfg.EARLY_HARD_PUNISH_ENABLED
    end
    enabled = enabled ~= false
    stats.hardPunishEnabled = enabled
    stats.earlyHardPunishEnabled = enabled
    local defensePressure = isDefensePressure(contracts)

    local canRun, skipReason = shouldRun(ai, state, ctx, contracts)
    if not canRun then
        stats.hardPunishSkipped = skipReason
        stats.earlyHardPunishSkipped = skipReason
        return nil
    end

    local function recordRejectedForPressure(selected, reason)
        if not defensePressure then
            return
        end
        stats.earlyHardPunishDefensePressureRejected =
            num(stats.earlyHardPunishDefensePressureRejected, 0) + 1
        stats.earlyHardPunishDefensePressureRejectReason = reason
        stats.earlyHardPunishDefensePressureRejectedKind = selected and selected.kind or nil
    end

    local function accept(selected)
        if not selected then
            return nil
        end
        local allowed, proof = allowSelectionForDefensePressure(ai, state, ctx, contracts, selected)
        if allowed then
            if defensePressure then
                return markDefensePressureSelection(selected, proof)
            end
            return selected
        end
        recordRejectedForPressure(selected, proof)
        return nil
    end

    local function recordSelected(selected)
        stats.earlyHardPunishSelected = selected.reason
        stats.earlyHardPunishSelectedUnit = unitText(selected.unit)
        if selected.secondUnit then
            stats.earlyHardPunishSelectedSecondUnit = unitText(selected.secondUnit)
        end
        stats.earlyHardPunishSelectedTarget = actionTargetText(selected.actions[#selected.actions])
        if defensePressure then
            stats.earlyHardPunishDefensePressureSelected = true
            stats.earlyHardPunishDefensePressureProof = selected.defensePressureProof
        end
    end

    if ctx.cfg.EARLY_HARD_PUNISH_DIRECT_KILL_ENABLED ~= false then
        local candidates = directCandidates(ai, state)
        stats.earlyHardPunishDirectSafeKills = #candidates
        for _, entry in ipairs(candidates) do
            local selected = accept(buildDirect(entry))
            if selected then
                recordSelected(selected)
                return selected
            end
        end
    else
        stats.earlyHardPunishDirectSafeKills = 0
    end

    if ctx.cfg.EARLY_HARD_PUNISH_MOVE_ATTACK_KILL_ENABLED ~= false then
        local candidates = moveAttackCandidates(ai, state)
        stats.earlyHardPunishMoveAttackSafeKills = #candidates
        for _, entry in ipairs(candidates) do
            local selected = accept(buildMoveAttack(entry))
            if selected then
                recordSelected(selected)
                return selected
            end
        end
    else
        stats.earlyHardPunishMoveAttackSafeKills = 0
    end

    if ctx.cfg.EARLY_HARD_PUNISH_TWO_UNIT_KILL_ENABLED ~= false then
        local candidates = twoUnitCandidates(ai, state)
        stats.earlyHardPunishTwoUnitSafeKills = #candidates
        for _, entry in ipairs(candidates) do
            local selected = accept(buildTwoUnit(entry))
            if selected then
                recordSelected(selected)
                return selected
            end
        end
    else
        stats.earlyHardPunishTwoUnitSafeKills = 0
    end

    if ctx.cfg.EARLY_HARD_PUNISH_CLOUDSTRIKER_LOS_KILL_ENABLED ~= false then
        local candidates = cloudstrikerLosCandidates(ai, state)
        stats.earlyHardPunishCloudstrikerLosSafeKills = #candidates
        for _, entry in ipairs(candidates) do
            local selected = accept(buildCloudstrikerLos(entry))
            if selected then
                recordSelected(selected)
                return selected
            end
        end
    else
        stats.earlyHardPunishCloudstrikerLosSafeKills = 0
    end

    if defensePressure then
        stats.earlyHardPunishRangedCommandantPressure = 0
        stats.hardPunishSkipped = "defense_pressure_safe_kill_unavailable"
        stats.earlyHardPunishSkipped = "defense_pressure_safe_kill_unavailable"
        return nil
    end

    local pressureEntry, pressureCount = rangedCommandantPressureCandidate(ai, state, ctx)
    stats.earlyHardPunishRangedCommandantPressure = pressureCount
    local pressureSelected = buildRangedCommandantPressure(pressureEntry)
    if pressureSelected then
        recordSelected(pressureSelected)
        return pressureSelected
    end

    stats.hardPunishSkipped = "no_safe_punish_kill_or_ranged_commandant_pressure"
    stats.earlyHardPunishSkipped = "no_safe_punish_kill_or_ranged_commandant_pressure"
    return nil
end

return M
