local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function getUnitAtPosition(ai, state, row, col)
    if not state then
        return nil
    end
    if ai and ai.getUnitAtPosition then
        return ai:getUnitAtPosition(state, row, col)
    end
    for _, unit in ipairs(state.units or {}) do
        if unit and unit.row == row and unit.col == col then
            return unit
        end
    end
    return nil
end

local function buildHubAsUnit(state, playerId)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if not hub then
        return nil
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

function M.repairTarget(ai, state, action)
    if not (action and action.type == "repair" and action.target) then
        return nil
    end

    local target = getUnitAtPosition(ai, state, action.target.row, action.target.col)
    if target then
        return target
    end

    for playerId = 1, 2 do
        local hub = state and state.commandHubs and state.commandHubs[playerId]
        if hub and hub.row == action.target.row and hub.col == action.target.col then
            return buildHubAsUnit(state, playerId)
        end
    end

    return nil
end

function M.repairMissingHp(ai, state, action)
    local target = M.repairTarget(ai, state, action)
    if not target then
        return nil, nil, nil, nil
    end

    local currentHp = num(target.currentHp, num(target.startingHp, 0))
    local maxHp = num(target.startingHp, currentHp)
    return math.max(0, maxHp - currentHp), target, currentHp, maxHp
end

function M.isFullHpRepair(ai, state, action)
    local missingHp, target, currentHp, maxHp = M.repairMissingHp(ai, state, action)
    return target ~= nil and num(maxHp, 0) > 0 and num(missingHp, 0) <= 0,
        target,
        currentHp,
        maxHp
end

function M.fullHpRepairCheapScoreCap(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_HP_REPAIR_CHEAP_SCORE_CAP, -24000)
end

function M.fullHpRepairScorePenalty(ctx)
    return math.max(0, num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_HP_REPAIR_SCORE_PENALTY, 14000))
end

function M.fullHpRepairSecondActionPenalty(ctx)
    return math.max(0, num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_HP_REPAIR_SECOND_ACTION_PENALTY, 18000))
end

function M.capFullHpRepairCheapScore(ai, state, action, cheapScore, ctx, tags)
    local fullHp, target, currentHp, maxHp = M.isFullHpRepair(ai, state, action)
    if not fullHp then
        return cheapScore
    end

    if tags then
        tags.fullHpRepair = true
        tags.fullHpRepairTarget = target and target.name or nil
        tags.fullHpRepairCurrentHp = currentHp
        tags.fullHpRepairMaxHp = maxHp
    end
    return math.min(num(cheapScore, 0), M.fullHpRepairCheapScoreCap(ctx))
end

local function simulateOne(ai, state, action, playerId, ctx)
    if not (state and action and action.type and action.type ~= "skip") then
        return state
    end
    if ctx and ctx.cache and ctx.cache.simulate then
        return ctx.cache.simulate(ai, state, {action}, playerId, ctx)
    end
    if ai and ai.simulateActionSequenceForPlayer then
        return ai:simulateActionSequenceForPlayer(state, {action}, playerId, {})
    end
    return nil
end

function M.sequenceFullHpRepairPenalty(ai, state, actions, ctx, playerId)
    local currentState = state
    local penalty = 0
    local count = 0
    local details = {}
    local actingPlayer = playerId or (ctx and ctx.aiPlayer) or state and state.currentPlayer or 1

    for index, action in ipairs(actions or {}) do
        if action and action.type == "repair" then
            local fullHp, target, currentHp, maxHp = M.isFullHpRepair(ai, currentState, action)
            if fullHp then
                count = count + 1
                penalty = penalty + M.fullHpRepairScorePenalty(ctx)
                details[#details + 1] = {
                    index = index,
                    target = target and target.name or nil,
                    row = action.target and action.target.row or nil,
                    col = action.target and action.target.col or nil,
                    currentHp = currentHp,
                    maxHp = maxHp
                }
            end
        end

        if index < #(actions or {}) then
            currentState = simulateOne(ai, currentState, action, actingPlayer, ctx)
            if not currentState then
                break
            end
        end
    end

    return {
        penalty = penalty,
        count = count,
        repairs = details
    }
end

return M
