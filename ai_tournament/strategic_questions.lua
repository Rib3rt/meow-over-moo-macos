local M = {}

local strategicPersonality = require("ai_tournament.strategic_personality")

local PURPOSES = {
    expand = {
        safeStaging = 70,
        move = 35,
        deploy = 25,
        support = 25,
        covered = 35,
        progress = 18,
        enemyPunish = -120,
        lethalPunish = -180
    },
    contain = {
        deny = 75,
        interdiction = 60,
        attackContested = 35,
        support = 20,
        covered = 45,
        enemyAttack = 8,
        enemyPunish = -90,
        lethalPunish = -150
    },
    support = {
        support = 80,
        heal = 45,
        move = 25,
        deploy = 20,
        covered = 45,
        enemyPunish = -120,
        lethalPunish = -180
    },
    pressure = {
        secondThreat = 85,
        safeStaging = 30,
        interdiction = 35,
        move = 20,
        deploy = 15,
        covered = 35,
        enemyPunish = -110,
        lethalPunish = -180
    },
    deploy = {
        deploy = 100,
        support = 25,
        deny = 20,
        safeStaging = 20,
        covered = 45,
        enemyPunish = -120,
        lethalPunish = -180
    },
    retreat = {
        heal = 75,
        move = 30,
        support = 25,
        covered = 50,
        enemyPunish = -60,
        lethalPunish = -90
    }
}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function mergeWeights(base, override)
    local out = {}
    for key, value in pairs(base or {}) do
        out[key] = value
    end
    for key, value in pairs(override or {}) do
        out[key] = value
    end
    return out
end

local function active(bucket)
    return bucket and bucket.active == true
end

local function count(bucket)
    return num(bucket and bucket.count, 0)
end

local function add(reasons, reason, amount)
    if amount ~= 0 then
        reasons[#reasons + 1] = {
            reason = reason,
            value = amount
        }
    end
end

local function cfg(opts, key, fallback)
    return num(opts and opts.ctx and opts.ctx.cfg and opts.ctx.cfg[key], fallback)
end

local function purposeWeights(purpose, opts)
    local key = tostring(purpose or "expand")
    local weights, personality = strategicPersonality.applyToWeights(
        PURPOSES[key] or PURPOSES.expand,
        key,
        opts and opts.ctx,
        opts
    )
    return mergeWeights(weights, opts and opts.weights or {}), personality
end

function M.scoreCell(cell, purpose, opts)
    opts = opts or {}
    local weights, personality = purposeWeights(purpose, opts)
    local opportunity = cell and cell.opportunity or {}
    local risk = cell and cell.risk or {}
    local value = num(cell and cell.strategicScore, 0) * num(weights.baseStrategicScale, 0.15)
    local reasons = {}
    local personalityName = tostring(personality and personality.name or "neutral_base")
    reasons[#reasons + 1] = {
        reason = "personality_" .. personalityName,
        value = 0
    }

    local function weighted(flag, weightName, reason)
        local weight = num(weights[weightName], 0)
        if flag and weight ~= 0 then
            value = value + weight
            add(reasons, reason, weight)
        end
    end

    weighted(opportunity.safeStaging, "safeStaging", "purpose_safe_staging")
    weighted(opportunity.support, "support", "purpose_support")
    weighted(opportunity.deny, "deny", "purpose_deny")
    weighted(opportunity.interdiction, "interdiction", "purpose_interdiction")
    weighted(opportunity.secondThreat, "secondThreat", "purpose_second_threat")
    weighted(active(cell and cell.moveInfluence and cell.moveInfluence.us), "move", "purpose_move_available")
    weighted(active(cell and cell.deployInfluence and cell.deployInfluence.us), "deploy", "purpose_deploy_available")
    weighted(active(cell and cell.healInfluence and cell.healInfluence.us), "heal", "purpose_heal_available")
    weighted(cell and cell.coveredIfOccupied == true, "covered", "purpose_covered_if_occupied")
    weighted(cell and cell.attackContested == true, "attackContested", "purpose_attack_contested")

    local progressValue = num(cell and cell.progress, 0) * num(weights.progress, 0)
    value = value + progressValue
    add(reasons, "purpose_progress", progressValue)

    local enemyAttackValue = count(cell and cell.attackInfluence and cell.attackInfluence.enemy)
        * num(weights.enemyAttack, 0)
    value = value + enemyAttackValue
    add(reasons, "purpose_enemy_attack_influence", enemyAttackValue)

    if risk.enemyPunish then
        local penalty = num(weights.enemyPunish, 0)
        value = value + penalty
        add(reasons, "purpose_enemy_punish", penalty)
    end
    if risk.lethalPunish then
        local penalty = num(weights.lethalPunish, 0)
        value = value + penalty
        add(reasons, "purpose_lethal_punish", penalty)
    end

    local fireLaneScore = num(cell and cell.fireLaneScore, num(cell and cell.fireLane and cell.fireLane.score, 0))
    if cell and cell.deadFireLane == true then
        local penalty = -math.abs(cfg(opts, "EARLY_DEAD_FIRE_LANE_PENALTY", 220))
        value = value + penalty
        add(reasons, "purpose_dead_fire_lane", penalty)
    elseif fireLaneScore > 0 then
        local bonus = math.min(
            fireLaneScore * cfg(opts, "EARLY_FIRE_LANE_QUESTION_WEIGHT", 0.35),
            cfg(opts, "EARLY_FIRE_LANE_QUESTION_CAP", 100)
        )
        value = value + bonus
        add(reasons, "purpose_route_fire_lane", bonus)
    end

    return {
        key = cell and cell.key,
        row = cell and cell.row,
        col = cell and cell.col,
        value = value,
        purpose = tostring(purpose or "expand"),
        personality = personalityName,
        cell = cell,
        reasons = reasons
    }
end

function M.ask(position, purpose, opts)
    opts = opts or {}
    local answers = {}
    local sourceCells = opts.cells or (position and position.strategicFreeCells) or (position and position.cells) or {}
    local minValue = num(opts.minValue, -math.huge)

    for _, cell in ipairs(sourceCells) do
        local scored = M.scoreCell(cell, purpose, opts)
        if scored.value >= minValue then
            answers[#answers + 1] = scored
        end
    end

    table.sort(answers, function(a, b)
        if a.value == b.value then
            return tostring(a.key or "") < tostring(b.key or "")
        end
        return a.value > b.value
    end)

    local limit = num(opts.limit, #answers)
    while #answers > limit do
        table.remove(answers)
    end

    return {
        kind = "strategic_question_answer",
        purpose = tostring(purpose or "expand"),
        personality = strategicPersonality.resolve(opts.ctx, opts.personality).name,
        position = position,
        answers = answers
    }
end

M.PURPOSES = PURPOSES
M.resolvePersonality = strategicPersonality.resolve

return M
