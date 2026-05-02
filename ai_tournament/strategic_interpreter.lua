local punishMap = require("ai_tournament.punish_map")

local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function cellKey(row, col)
    if type(row) == "table" then
        col = row.col
        row = row.row
    end
    return tostring(num(row, 0)) .. "," .. tostring(num(col, 0))
end

local function phaseName(ctx)
    return tostring(ctx and ctx.phase and ctx.phase.name or ctx and ctx.phase or "unknown")
end

local function hasKind(cell, kind)
    for _, value in ipairs((cell and cell.kinds) or {}) do
        if value == kind then
            return true
        end
    end
    return false
end

local function addFact(facts, fact)
    facts[#facts + 1] = fact
end

local function sortCells(cells)
    table.sort(cells, function(a, b)
        if num(a.salience, 0) == num(b.salience, 0) then
            return tostring(a.key or "") < tostring(b.key or "")
        end
        return num(a.salience, 0) > num(b.salience, 0)
    end)
end

local function insertZone(zones, name, cell)
    zones[name] = zones[name] or {}
    zones[name][#zones[name] + 1] = cell
end

local function enrichCell(key, influence, strategicCell)
    local facts = {}
    local control = influence and influence.control or {}
    local attack = influence and influence.attackInfluence or {}
    local move = influence and influence.moveInfluence or {}
    local moveAttack = influence and influence.moveAttackInfluence or {}
    local deploy = influence and influence.deployInfluence or {}
    local heal = influence and influence.healInfluence or {}
    local usAttack = attack.us or {}
    local enemyAttack = attack.enemy or {}
    local usMove = move.us or {}
    local enemyMove = move.enemy or {}
    local usMoveAttack = moveAttack.us or {}
    local enemyMoveAttack = moveAttack.enemy or {}
    local usDeploy = deploy.us or {}
    local enemyDeploy = deploy.enemy or {}
    local usHeal = heal.us or {}
    local enemyHeal = heal.enemy or {}

    if control.us then addFact(facts, "occupied_us") end
    if control.enemy then addFact(facts, "occupied_enemy") end
    if control.neutral then addFact(facts, "occupied_neutral") end
    if usAttack.active then addFact(facts, "attack_influence_us") end
    if enemyAttack.active then addFact(facts, "attack_influence_enemy") end
    if usMove.active then addFact(facts, "move_influence_us") end
    if enemyMove.active then addFact(facts, "move_influence_enemy") end
    if usMoveAttack.active then addFact(facts, "move_attack_influence_us") end
    if enemyMoveAttack.active then addFact(facts, "move_attack_influence_enemy") end
    if usDeploy.active then addFact(facts, "deploy_influence_us") end
    if enemyDeploy.active then addFact(facts, "deploy_influence_enemy") end
    if usHeal.active then addFact(facts, "heal_influence_us") end
    if enemyHeal.active then addFact(facts, "heal_influence_enemy") end
    if influence and influence.attackContested then addFact(facts, "attack_contested") end
    if influence and influence.contested then addFact(facts, "influence_contested") end
    if influence and influence.potentialContested then addFact(facts, "potential_influence_contested") end

    for _, kind in ipairs((strategicCell and strategicCell.kinds) or {}) do
        addFact(facts, "kind_" .. tostring(kind))
    end
    for _, reason in ipairs((strategicCell and strategicCell.reasons) or {}) do
        addFact(facts, "reason_" .. tostring(reason))
    end

    local enemyPunish = strategicCell and strategicCell.enemyPunish or nil
    local coveredIfOccupied = strategicCell and strategicCell.coveredIfOccupied == true or false
    local fireLane = strategicCell and strategicCell.fireLane or nil
    local fireLaneScore = num(strategicCell and strategicCell.fireLaneScore, num(fireLane and fireLane.score, 0))
    local fireLaneControlledCount =
        num(strategicCell and strategicCell.fireLaneControlledCount, num(fireLane and fireLane.controlledCount, 0))
    local deadFireLane = strategicCell and strategicCell.deadFireLane == true or false
    local salience = num(strategicCell and strategicCell.score, 0)
        + (influence and influence.attackContested and 35 or 0)
        + (influence and influence.contested and 20 or 0)
        + (usDeploy.active and 12 or 0)
        + (usHeal.active and 8 or 0)

    if fireLaneScore > 0 then addFact(facts, "route_fire_lane") end
    if deadFireLane then addFact(facts, "dead_fire_lane") end

    return {
        key = key,
        row = influence and influence.row or strategicCell and strategicCell.row,
        col = influence and influence.col or strategicCell and strategicCell.col,
        phase = nil,
        occupiedBy = influence and influence.occupiedBy or nil,
        control = control,
        attackInfluence = attack,
        moveInfluence = move,
        moveAttackInfluence = moveAttack,
        deployInfluence = deploy,
        healInfluence = heal,
        influencedByUs = influence and influence.influencedByUs == true or false,
        influencedByEnemy = influence and influence.influencedByEnemy == true or false,
        potentialInfluencedByUs = influence and influence.potentialInfluencedByUs == true or false,
        potentialInfluencedByEnemy = influence and influence.potentialInfluencedByEnemy == true or false,
        attackContested = influence and influence.attackContested == true or false,
        influenceContested = influence and influence.contested == true or false,
        potentialInfluenceContested = influence and influence.potentialContested == true or false,
        kinds = strategicCell and strategicCell.kinds or {},
        strategicScore = num(strategicCell and strategicCell.score, 0),
        progress = num(strategicCell and strategicCell.progress, 0),
        coveredIfOccupied = coveredIfOccupied,
        fireLane = fireLane,
        fireLaneScore = fireLaneScore,
        fireLaneControlledCount = fireLaneControlledCount,
        deadFireLane = deadFireLane,
        enemyPunish = enemyPunish,
        counterPunish = strategicCell and strategicCell.counterPunish or nil,
        tradeNet = num(strategicCell and strategicCell.tradeNet, 0),
        facts = facts,
        salience = salience,
        risk = {
            enemyAttack = num(enemyAttack.count, 0),
            enemyMove = num(enemyMove.count, 0),
            enemyMoveAttack = num(enemyMoveAttack.count, 0),
            enemyDeploy = num(enemyDeploy.count, 0),
            enemyHeal = num(enemyHeal.count, 0),
            enemyPunish = enemyPunish ~= nil,
            lethalPunish = enemyPunish and enemyPunish.lethal == true or false,
            coveredIfOccupied = coveredIfOccupied,
            deadFireLane = deadFireLane
        },
        opportunity = {
            attack = num(usAttack.count, 0),
            move = num(usMove.count, 0),
            moveAttack = num(usMoveAttack.count, 0),
            deploy = num(usDeploy.count, 0),
            heal = num(usHeal.count, 0),
            support = hasKind(strategicCell, "support"),
            deny = hasKind(strategicCell, "deny"),
            interdiction = hasKind(strategicCell, "interdiction"),
            choke = hasKind(strategicCell, "choke"),
            safeStaging = hasKind(strategicCell, "safe_staging"),
            secondThreat = hasKind(strategicCell, "second_threat"),
            fireLane = fireLaneScore > 0
        }
    }
end

function M.interpret(state, ai, ctx, opts)
    opts = opts or {}
    local built = punishMap.build(state, ai, ctx)
    local strategic = built.strategicFreeCellsByKey or {}
    local result = {
        kind = "neutral_position_interpretation",
        version = 1,
        phase = phaseName(ctx),
        playerId = built.playerId,
        enemyPlayer = built.enemyPlayer,
        purpose = nil,
        byKey = {},
        cells = {},
        strategicFreeCells = {},
        zones = {
            occupiedUs = {},
            occupiedEnemy = {},
            attackInfluencedByUs = {},
            attackInfluencedByEnemy = {},
            moveReachableUs = {},
            deployableUs = {},
            healableUs = {},
            attackContested = {},
            influenceContested = {},
            expansionCandidates = {},
            denyCandidates = {},
            supportCandidates = {},
            secondThreatCandidates = {},
            riskCells = {},
            potentialInfluenceContested = {}
        },
        source = built
    }

    for key, influence in pairs(built.influenceByKey or {}) do
        local cell = enrichCell(key, influence, strategic[key])
        cell.phase = result.phase
        result.byKey[key] = cell
        result.cells[#result.cells + 1] = cell

        if cell.control.us then insertZone(result.zones, "occupiedUs", cell) end
        if cell.control.enemy then insertZone(result.zones, "occupiedEnemy", cell) end
        if cell.attackInfluence.us and cell.attackInfluence.us.active then
            insertZone(result.zones, "attackInfluencedByUs", cell)
        end
        if cell.attackInfluence.enemy and cell.attackInfluence.enemy.active then
            insertZone(result.zones, "attackInfluencedByEnemy", cell)
        end
        if cell.moveInfluence.us and cell.moveInfluence.us.active then
            insertZone(result.zones, "moveReachableUs", cell)
        end
        if cell.deployInfluence.us and cell.deployInfluence.us.active then
            insertZone(result.zones, "deployableUs", cell)
        end
        if cell.healInfluence.us and cell.healInfluence.us.active then
            insertZone(result.zones, "healableUs", cell)
        end
        if cell.attackContested then insertZone(result.zones, "attackContested", cell) end
        if cell.influenceContested then insertZone(result.zones, "influenceContested", cell) end
        if cell.potentialInfluenceContested then insertZone(result.zones, "potentialInfluenceContested", cell) end
        if cell.opportunity.safeStaging then insertZone(result.zones, "expansionCandidates", cell) end
        if cell.opportunity.deny or cell.opportunity.interdiction then insertZone(result.zones, "denyCandidates", cell) end
        if cell.opportunity.support then insertZone(result.zones, "supportCandidates", cell) end
        if cell.opportunity.secondThreat then insertZone(result.zones, "secondThreatCandidates", cell) end
        if cell.risk.enemyPunish then insertZone(result.zones, "riskCells", cell) end
        if strategic[key] then
            result.strategicFreeCells[#result.strategicFreeCells + 1] = cell
        end
    end

    sortCells(result.cells)
    sortCells(result.strategicFreeCells)
    for _, list in pairs(result.zones) do
        sortCells(list)
    end

    return result
end

return M
