local M = {}

M.TIER = {
    WIN_NOW = 100,
    AVOID_LOSS = 90,
    FORCE_WIN_NEXT = 80,
    STOP_FORCE = 70,
    MAJOR_ADVANTAGE = 60,
    NORMAL = 50,
    BAD_BUT_LEGAL = 10,
    INVALID = -100
}

local ORDER = {
    "tier",
    "terminal",
    "survival",
    "force",
    "commandant",
    "material",
    "supply",
    "position",
    "risk",
    "efficiency"
}

function M.new(signature)
    return {
        tier = M.TIER.NORMAL,
        terminal = 0,
        survival = 0,
        force = 0,
        commandant = 0,
        material = 0,
        supply = 0,
        position = 0,
        risk = 0,
        efficiency = 0,
        total = 0,
        signature = signature or "",
        breakdown = {}
    }
end

function M.finalize(s)
    if type(s) ~= "table" then
        return s
    end

    s.total =
        (s.terminal or 0) +
        (s.survival or 0) +
        (s.force or 0) +
        (s.commandant or 0) +
        (s.material or 0) +
        (s.supply or 0) +
        (s.position or 0) +
        (s.risk or 0) +
        (s.efficiency or 0)

    return s
end

function M.isBetter(a, b)
    if not a then
        return false
    end
    if not b then
        return true
    end

    for _, key in ipairs(ORDER) do
        local av = tonumber(a[key]) or 0
        local bv = tonumber(b[key]) or 0
        if av ~= bv then
            return av > bv
        end
    end

    local as = tostring(a.signature or "")
    local bs = tostring(b.signature or "")
    return as < bs
end

return M
