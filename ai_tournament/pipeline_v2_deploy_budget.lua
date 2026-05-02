local M = {}
local budgetScope = require("ai_tournament.pipeline_v2_budget_scope")

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function clamp(value, minValue, maxValue)
    local n = num(value, minValue)
    if n < minValue then
        return minValue
    end
    if n > maxValue then
        return maxValue
    end
    return n
end

local function statKey(prefix, suffix)
    return tostring(prefix or "pipelineV2Deploy") .. tostring(suffix or "")
end

function M.collectEntries(ai, state, ctx, opts)
    if not (ctx and ctx.supplyPlanner and ctx.supplyPlanner.getDeployActionEntries) then
        return {}
    end

    local options = opts or {}
    local stats = ctx.stats
    local prefix = options.statPrefix or "pipelineV2Deploy"
    local extraMs = clamp(ctx.cfg and ctx.cfg.PIPELINE_V2_DEPLOY_EXTRA_MS or 0, 0, 5000)
    local useExtra = extraMs > 0 and ctx._pipelineV2DeployBudgetActive ~= true
    local budget = nil

    if useExtra then
        ctx._pipelineV2DeployBudgetActive = true
        budget = budgetScope.push(ctx, stats, {
            extraMs = extraMs,
            extraKey = statKey(prefix, "BudgetExtraMs"),
            remainingKey = statKey(prefix, "BudgetRemainingBeforeMs"),
            startKey = statKey(prefix, "BudgetStartElapsedMs"),
            extendedKey = statKey(prefix, "BudgetExtendedHardBudgetMs"),
            localWindowKey = statKey(prefix, "BudgetLocalWindowMs")
        })
        if stats then
            stats[statKey(prefix, "BudgetUses")] =
                num(stats[statKey(prefix, "BudgetUses")], 0) + 1
        end
    end

    local entries = ctx.supplyPlanner.getDeployActionEntries(ai, state, ctx.aiPlayer, ctx) or {}

    if useExtra then
        if budget then
            budget.pop()
        end
        ctx._pipelineV2DeployBudgetActive = false
    end

    if stats then
        stats[statKey(prefix, "BudgetReturned")] = #entries
    end
    return entries
end

return M
