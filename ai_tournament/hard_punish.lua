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

local function shouldRun(ai, state, ctx, contracts)
    if not (ai and state and ctx and ctx.cfg) then
        return false, "missing_context"
    end
    if ctx.cfg.EARLY_HARD_PUNISH_ENABLED == false then
        return false, "disabled"
    end
    if not (ctx.phase and ctx.phase.early == true) then
        return false, "not_early"
    end
    if contracts and contracts.defenseActive == true then
        return false, "hard_defense_contract"
    end
    if not (ai.findSafeKillAttacks and ai.findSafeMoveAttackKills) then
        return false, "hard_safe_kill_tools_unavailable"
    end
    return true, nil
end

local function directCandidate(ai, state)
    local candidates = ai:findSafeKillAttacks(state, {}) or {}
    return candidates[1], #candidates
end

local function moveAttackCandidate(ai, state)
    local candidates = ai:findSafeMoveAttackKills(state, {}) or {}
    return candidates[1], #candidates
end

local function twoUnitCandidate(ai, state)
    if not (ai and ai.findTwoUnitKillCombinations) then
        return nil, 0
    end
    local candidates = ai:findTwoUnitKillCombinations(state, {}, true) or {}
    return candidates[1], #candidates
end

local function cloudstrikerLosCandidate(ai, state)
    if not (ai and ai.findCorvetteLineOfSightKills) then
        return nil, 0
    end
    local candidates = ai:findCorvetteLineOfSightKills(state, {}) or {}
    return candidates[1], #candidates
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
    local enabled = ctx and ctx.cfg and ctx.cfg.EARLY_HARD_PUNISH_ENABLED ~= false
    stats.earlyHardPunishEnabled = enabled

    local canRun, skipReason = shouldRun(ai, state, ctx, contracts)
    if not canRun then
        stats.earlyHardPunishSkipped = skipReason
        return nil
    end

    if ctx.cfg.EARLY_HARD_PUNISH_DIRECT_KILL_ENABLED ~= false then
        local entry, count = directCandidate(ai, state)
        stats.earlyHardPunishDirectSafeKills = count
        local selected = buildDirect(entry)
        if selected then
            stats.earlyHardPunishSelected = selected.reason
            stats.earlyHardPunishSelectedUnit = unitText(selected.unit)
            stats.earlyHardPunishSelectedTarget = actionTargetText(selected.actions[1])
            return selected
        end
    else
        stats.earlyHardPunishDirectSafeKills = 0
    end

    if ctx.cfg.EARLY_HARD_PUNISH_MOVE_ATTACK_KILL_ENABLED ~= false then
        local entry, count = moveAttackCandidate(ai, state)
        stats.earlyHardPunishMoveAttackSafeKills = count
        local selected = buildMoveAttack(entry)
        if selected then
            stats.earlyHardPunishSelected = selected.reason
            stats.earlyHardPunishSelectedUnit = unitText(selected.unit)
            stats.earlyHardPunishSelectedTarget = actionTargetText(selected.actions[2])
            return selected
        end
    else
        stats.earlyHardPunishMoveAttackSafeKills = 0
    end

    if ctx.cfg.EARLY_HARD_PUNISH_TWO_UNIT_KILL_ENABLED ~= false then
        local entry, count = twoUnitCandidate(ai, state)
        stats.earlyHardPunishTwoUnitSafeKills = count
        local selected = buildTwoUnit(entry)
        if selected then
            stats.earlyHardPunishSelected = selected.reason
            stats.earlyHardPunishSelectedUnit = unitText(selected.unit)
            stats.earlyHardPunishSelectedSecondUnit = unitText(selected.secondUnit)
            stats.earlyHardPunishSelectedTarget = actionTargetText(selected.actions[2])
            return selected
        end
    else
        stats.earlyHardPunishTwoUnitSafeKills = 0
    end

    if ctx.cfg.EARLY_HARD_PUNISH_CLOUDSTRIKER_LOS_KILL_ENABLED ~= false then
        local entry, count = cloudstrikerLosCandidate(ai, state)
        stats.earlyHardPunishCloudstrikerLosSafeKills = count
        local selected = buildCloudstrikerLos(entry)
        if selected then
            stats.earlyHardPunishSelected = selected.reason
            stats.earlyHardPunishSelectedUnit = unitText(selected.unit)
            stats.earlyHardPunishSelectedSecondUnit = unitText(selected.secondUnit)
            stats.earlyHardPunishSelectedTarget = actionTargetText(selected.actions[2])
            return selected
        end
    else
        stats.earlyHardPunishCloudstrikerLosSafeKills = 0
    end

    local pressureEntry, pressureCount = rangedCommandantPressureCandidate(ai, state, ctx)
    stats.earlyHardPunishRangedCommandantPressure = pressureCount
    local pressureSelected = buildRangedCommandantPressure(pressureEntry)
    if pressureSelected then
        stats.earlyHardPunishSelected = pressureSelected.reason
        stats.earlyHardPunishSelectedUnit = unitText(pressureSelected.unit)
        stats.earlyHardPunishSelectedTarget = actionTargetText(pressureSelected.actions[#pressureSelected.actions])
        return pressureSelected
    end

    stats.earlyHardPunishSkipped = "no_safe_punish_kill_or_ranged_commandant_pressure"
    return nil
end

return M
