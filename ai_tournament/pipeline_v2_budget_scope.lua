local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

function M.push(ctx, stats, opts)
    local options = opts or {}
    local extraMs = math.max(0, num(options.extraMs, 0))
    if not (ctx and extraMs > 0) then
        return {
            active = false,
            pop = function() end
        }
    end

    local originalHardBudgetMs = ctx.hardBudgetMs
    local elapsedMs = ctx.elapsedMs and ctx.elapsedMs() or 0
    local remainingBeforeMs = ctx.remainingMs and ctx.remainingMs()
        or math.max(0, num(originalHardBudgetMs, 0) - elapsedMs)
    local extendedHardBudgetMs = math.max(num(originalHardBudgetMs, 0), elapsedMs + extraMs)

    ctx.hardBudgetMs = extendedHardBudgetMs

    if stats then
        if options.extraKey then
            stats[options.extraKey] = extraMs
        end
        if options.remainingKey then
            stats[options.remainingKey] = remainingBeforeMs
        end
        if options.startKey then
            stats[options.startKey] = elapsedMs
        end
        if options.extendedKey then
            stats[options.extendedKey] = extendedHardBudgetMs
        end
        if options.localWindowKey then
            stats[options.localWindowKey] = math.max(0, extendedHardBudgetMs - elapsedMs)
        end
    end

    return {
        active = true,
        originalHardBudgetMs = originalHardBudgetMs,
        extendedHardBudgetMs = extendedHardBudgetMs,
        pop = function()
            ctx.hardBudgetMs = originalHardBudgetMs
        end
    }
end

return M
