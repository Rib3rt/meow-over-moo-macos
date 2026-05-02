local M = {}

local DEFAULT_PROFILE = {
    name = "base",
    label = "neutral",
    weights = {
        map = 0.42,
        pressure = 1.00,
        expansion = 1.00,
        attack = 0.95,
        contest = 0.85,
        trade = 1.00,
        cover = 1.00,
        risk = 1.00,
        command = 1.00
    },
    thresholds = {
        minCellValue = 60,
        minTradeNet = 0,
        attackMinTradeNet = 0,
        minMaterialDelta = 18,
        minAttackDamage = 1
    }
}

local BUILTIN_PROFILES = {
    base = DEFAULT_PROFILE,
    lisa = {
        name = "lisa",
        label = "neutral",
        weights = {
            map = 0.42,
            pressure = 1.00,
            expansion = 1.00,
            attack = 0.95,
            contest = 0.85,
            trade = 1.00,
            cover = 1.00,
            risk = 1.00,
            command = 1.00
        },
        thresholds = {
            minCellValue = 60,
            minTradeNet = 0,
            attackMinTradeNet = 0,
            minMaterialDelta = 18,
            minAttackDamage = 1
        }
    },
    maggie = {
        name = "maggie",
        label = "active_balance",
        weights = {
            map = 0.40,
            pressure = 1.10,
            expansion = 1.08,
            attack = 1.08,
            contest = 1.00,
            trade = 1.08,
            cover = 1.05,
            risk = 0.92,
            command = 1.02
        },
        thresholds = {
            minCellValue = 55,
            minTradeNet = 0,
            attackMinTradeNet = 0,
            minMaterialDelta = 10,
            minAttackDamage = 1
        }
    },
    burt = {
        name = "burt",
        label = "assertive_pressure",
        weights = {
            map = 0.36,
            pressure = 1.34,
            expansion = 1.14,
            attack = 1.44,
            contest = 1.26,
            trade = 1.14,
            cover = 0.78,
            risk = 0.70,
            command = 1.18
        },
        thresholds = {
            minCellValue = 35,
            minTradeNet = -1,
            attackMinTradeNet = -1,
            minMaterialDelta = -4,
            minAttackDamage = 1
        }
    },
    barnes = {
        name = "barnes",
        label = "aggressive_pressure",
        alias = "burt"
    },
    marge = {
        name = "marge",
        label = "defensive_anchor",
        weights = {
            map = 0.48,
            pressure = 0.62,
            expansion = 0.82,
            attack = 0.42,
            contest = 0.32,
            trade = 1.36,
            cover = 1.68,
            risk = 1.86,
            command = 0.64
        },
        thresholds = {
            minCellValue = 108,
            minTradeNet = 2,
            attackMinTradeNet = 2,
            minMaterialDelta = 52,
            minAttackDamage = 1
        }
    },
    homer = {
        name = "homer",
        label = "cautious_balance",
        weights = {
            map = 0.44,
            pressure = 0.80,
            expansion = 0.92,
            attack = 0.66,
            contest = 0.54,
            trade = 1.16,
            cover = 1.32,
            risk = 1.42,
            command = 0.82
        },
        thresholds = {
            minCellValue = 86,
            minTradeNet = 1,
            attackMinTradeNet = 1,
            minMaterialDelta = 34,
            minAttackDamage = 1
        }
    },
    burns = {
        name = "burns",
        label = "maximum_aggression",
        weights = {
            map = 0.30,
            pressure = 1.56,
            expansion = 1.18,
            attack = 1.88,
            contest = 1.56,
            trade = 1.20,
            cover = 0.60,
            risk = 0.44,
            command = 1.58
        },
        thresholds = {
            minCellValue = 28,
            minTradeNet = -2,
            attackMinTradeNet = -2,
            minMaterialDelta = -18,
            minAttackDamage = 1
        }
    }
}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function clone(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[key] = clone(child)
    end
    return out
end

local function merge(base, override)
    local out = clone(base or {})
    for key, value in pairs(override or {}) do
        if type(value) == "table" and type(out[key]) == "table" then
            out[key] = merge(out[key], value)
        else
            out[key] = clone(value)
        end
    end
    return out
end

local function normalized(value)
    if value == nil then
        return nil
    end
    local text = tostring(value):lower()
    if text == "" then
        return nil
    end
    return text
end

local function requestedReference(ai, state, ctx, override)
    local direct = normalized(override)
    if direct then
        return direct
    end

    local cfg = ctx and ctx.cfg or {}
    direct = normalized(cfg.MID_PERSONALITY or cfg.TOURNAMENT_MID_PERSONALITY)
    if direct then
        return direct
    end

    direct = normalized(ctx and (ctx.midPersonalityReference or ctx.aiReference))
    if direct then
        return direct
    end

    direct = normalized(ai and ai.aiReference)
    if direct then
        return direct
    end

    if ai and ai.getEffectiveAiReference then
        local ok, value = pcall(ai.getEffectiveAiReference, ai, state, {
            factionId = ctx and ctx.aiPlayer
        })
        if ok then
            direct = normalized(value)
            if direct then
                return direct
            end
        end
    end

    return "base"
end

local function profileFromTables(reference, configured)
    local builtin = BUILTIN_PROFILES[reference] or BUILTIN_PROFILES.base
    if builtin and builtin.alias then
        builtin = BUILTIN_PROFILES[builtin.alias] or builtin
    end

    local profile = merge(DEFAULT_PROFILE, builtin or {})
    local override = configured and configured[reference] or nil
    if override == nil and reference == "base" and configured then
        override = configured.neutral_base
    end
    profile = merge(profile, override or {})
    profile.name = tostring(profile.name or reference or "base")
    profile.reference = reference
    profile.label = tostring(profile.label or profile.name)
    return profile
end

function M.resolve(ai, state, ctx, override)
    local cfg = ctx and ctx.cfg or {}
    local reference = requestedReference(ai, state, ctx, override)
    return profileFromTables(reference, cfg.MID_PERSONALITIES or cfg.TOURNAMENT_MID_PERSONALITIES or {})
end

local function add(reasons, components, name, raw, weight)
    raw = num(raw, 0)
    weight = num(weight, 1)
    local value = raw * weight
    components[name] = value
    if value ~= 0 then
        reasons[#reasons + 1] = {
            reason = "mid_personality_" .. name,
            value = value
        }
    end
    return value
end

local function commandPressure(cell)
    local distance = num(cell and cell.enemyHubDistance, 99)
    if distance <= 2 then
        return 105
    elseif distance <= 4 then
        return 72
    elseif distance <= 6 then
        return 38
    end
    return 0
end

local function rawComponents(cell)
    local status = tostring(cell and cell.status or "other")
    local pressure = num(cell and cell.pressureQuestionValue, 0) * 0.08
        + num(cell and cell.ownAttackCount, 0) * 20
        + num(cell and cell.ownMoveAttackCount, 0) * 34
    if status == "pressure_cell" then
        pressure = pressure + 48
    elseif status == "contested_pressure" then
        pressure = pressure + 64
    end

    local expansion = num(cell and cell.progress, 0) * 18
        + (cell and cell.reachable and 34 or 0)
        + (cell and cell.deployable and 18 or 0)
        + (cell and cell.free and 8 or 0)
        + math.max(0, 7 - num(cell and cell.enemyHubDistance, 99)) * 6

    local attack = (cell and cell.attackableEnemy and 126 or 0)
        + (cell and cell.occupiedByEnemy and 48 or 0)
        + num(cell and cell.ownAttackCount, 0) * 18
        + num(cell and cell.ownMoveAttackCount, 0) * 24

    local contest = (cell and cell.attackContested and 78 or 0)
        + (cell and cell.influenceContested and 42 or 0)
        + (cell and cell.potentialInfluenceContested and 22 or 0)

    local tradeNet = num(cell and cell.tradeNet, 0)
    local trade = (tradeNet >= 0 and tradeNet * 42 or tradeNet * 58)
        + (cell and cell.coveredIfOccupied and 52 or 0)

    local cover = (cell and cell.coveredIfOccupied and 66 or 0)
        + (cell and cell.occupiedByUs and 24 or 0)

    local risk = (cell and cell.directlyAttackableByEnemy and 54 or 0)
        + num(cell and cell.enemyAttackCount, 0) * 18
        + num(cell and cell.enemyMoveAttackCount, 0) * 14
    if cell and cell.enemyPunish then
        risk = risk + (cell.enemyPunish.lethal and 160 or 78)
    end
    if tradeNet < 0 then
        risk = risk + math.abs(tradeNet) * 34
    end

    return {
        map = num(cell and cell.value, 0),
        pressure = pressure,
        expansion = expansion,
        attack = attack,
        contest = contest,
        trade = trade,
        cover = cover,
        risk = risk,
        command = commandPressure(cell)
    }
end

local function compactReasons(reasons, limit)
    local sorted = {}
    for _, entry in ipairs(reasons or {}) do
        sorted[#sorted + 1] = entry
    end
    table.sort(sorted, function(a, b)
        local av = math.abs(num(a and a.value, 0))
        local bv = math.abs(num(b and b.value, 0))
        if av == bv then
            return tostring(a and a.reason or "") < tostring(b and b.reason or "")
        end
        return av > bv
    end)

    local out = {}
    for index, entry in ipairs(sorted) do
        if index > limit then
            break
        end
        out[#out + 1] = tostring(entry.reason or entry):gsub("^mid_personality_", "")
    end
    return out
end

local function riskBand(cell, profile)
    local thresholds = profile.thresholds or {}
    local tradeNet = num(cell and cell.tradeNet, 0)
    if cell and cell.enemyPunish and cell.enemyPunish.lethal then
        return tradeNet >= num(thresholds.minTradeNet, 0) and "lethal_trade" or "lethal_bad_trade"
    end
    if cell and cell.directlyAttackableByEnemy then
        return tradeNet >= num(thresholds.minTradeNet, 0) and "contested_ok" or "contested_bad_trade"
    end
    if cell and cell.attackContested then
        return "contested"
    end
    return "stable"
end

local function strongestIntent(components)
    local bestName = "position"
    local bestValue = -math.huge
    for _, name in ipairs({"attack", "pressure", "contest", "expansion", "trade", "cover", "command"}) do
        local value = num(components and components[name], 0)
        if value > bestValue then
            bestName = name
            bestValue = value
        end
    end
    return bestName
end

function M.scoreCell(ai, state, ctx, cell, options)
    options = options or {}
    local profile = options.profile or M.resolve(ai, state, ctx, options.reference)
    local weights = profile.weights or DEFAULT_PROFILE.weights
    local thresholds = profile.thresholds or DEFAULT_PROFILE.thresholds
    local raw = rawComponents(cell)
    local components = {}
    local reasons = {}
    local total = 0

    total = total + add(reasons, components, "map", raw.map, weights.map)
    total = total + add(reasons, components, "pressure", raw.pressure, weights.pressure)
    total = total + add(reasons, components, "expansion", raw.expansion, weights.expansion)
    total = total + add(reasons, components, "attack", raw.attack, weights.attack)
    total = total + add(reasons, components, "contest", raw.contest, weights.contest)
    total = total + add(reasons, components, "trade", raw.trade, weights.trade)
    total = total + add(reasons, components, "cover", raw.cover, weights.cover)
    total = total - add(reasons, components, "risk", raw.risk, weights.risk)
    total = total + add(reasons, components, "command", raw.command, weights.command)

    if cell and cell.status == "blocked" then
        total = total - 1000
        reasons[#reasons + 1] = {reason = "mid_personality_blocked", value = -1000}
    elseif cell and cell.status == "own_commandant" then
        total = total - 700
        reasons[#reasons + 1] = {reason = "mid_personality_own_commandant", value = -700}
    end

    local band = riskBand(cell, profile)
    local accepted = total >= num(thresholds.minCellValue, 0)
    if cell and cell.attackableEnemy then
        accepted = accepted and num(cell.tradeNet, 0) >= num(thresholds.attackMinTradeNet, thresholds.minTradeNet or 0)
    end

    return {
        key = cell and cell.key,
        row = cell and cell.row,
        col = cell and cell.col,
        status = cell and cell.status,
        personality = profile.name,
        reference = profile.reference,
        label = profile.label,
        value = total,
        raw = raw,
        components = components,
        thresholds = thresholds,
        intent = strongestIntent(components),
        riskBand = band,
        acceptedForMid = accepted == true,
        attackableEnemy = cell and cell.attackableEnemy == true or false,
        directlyAttackableByEnemy = cell and cell.directlyAttackableByEnemy == true or false,
        attackContested = cell and cell.attackContested == true or false,
        tradeNet = num(cell and cell.tradeNet, 0),
        cell = cell,
        reasons = reasons,
        compactReasons = compactReasons(reasons, 5)
    }
end

local function topCells(cells, limit, predicate)
    local out = {}
    for _, cell in ipairs(cells or {}) do
        if not predicate or predicate(cell) then
            out[#out + 1] = cell
            if #out >= limit then
                break
            end
        end
    end
    return out
end

local function summarizeTop(top)
    local out = {}
    for _, cell in ipairs(top or {}) do
        out[#out + 1] = table.concat({
            tostring(cell.row) .. "," .. tostring(cell.col),
            tostring(cell.status or "unknown"),
            tostring(math.floor(num(cell.value, 0))),
            tostring(cell.intent or "position"),
            tostring(cell.riskBand or "stable"),
            table.concat(cell.compactReasons or {}, "+")
        }, ":")
    end
    return out
end

function M.interpretMap(ai, state, ctx, midMap, options)
    options = options or {}
    local profile = M.resolve(ai, state, ctx, options.reference)
    local cells = {}
    local byKey = {}
    for _, cell in ipairs((midMap and midMap.cells) or {}) do
        local scored = M.scoreCell(ai, state, ctx, cell, {
            profile = profile
        })
        cells[#cells + 1] = scored
        byKey[scored.key] = scored
    end

    table.sort(cells, function(a, b)
        if num(a.value, 0) == num(b.value, 0) then
            return tostring(a.key or "") < tostring(b.key or "")
        end
        return num(a.value, 0) > num(b.value, 0)
    end)

    local limit = math.max(1, num(options.limit, ctx and ctx.cfg and ctx.cfg.MID_PERSONALITY_TOP_N or 8))
    local result = {
        kind = "mid_personality_interpretation",
        version = 1,
        profile = profile,
        cells = cells,
        byKey = byKey,
        top = topCells(cells, limit, function(cell)
            return cell.status ~= "blocked" and cell.status ~= "own_commandant"
        end),
        attackTargets = topCells(cells, limit, function(cell)
            return cell.attackableEnemy == true
        end),
        positionTargets = topCells(cells, limit, function(cell)
            return cell.cell and cell.cell.free == true and (cell.cell.reachable == true or cell.cell.deployable == true)
        end),
        contestedTargets = topCells(cells, limit, function(cell)
            return cell.attackContested == true or cell.riskBand == "contested_ok" or cell.riskBand == "contested"
        end),
        tradeTargets = topCells(cells, limit, function(cell)
            return num(cell.tradeNet, 0) >= num(profile.thresholds and profile.thresholds.minTradeNet, 0)
        end),
        source = midMap
    }

    if ctx and ctx.stats then
        ctx.stats.midPersonalityName = profile.name
        ctx.stats.midPersonalityReference = profile.reference
        ctx.stats.midPersonalityLabel = profile.label
        ctx.stats.midPersonalityTop = summarizeTop(result.top)
        ctx.stats.midPersonalityAttackTargets = summarizeTop(result.attackTargets)
        ctx.stats.midPersonalityPositionTargets = summarizeTop(result.positionTargets)
        ctx.stats.midPersonalityContestedTargets = summarizeTop(result.contestedTargets)
        ctx.stats.midPersonalityTradeTargets = summarizeTop(result.tradeTargets)
    end

    return result
end

M.BUILTIN_PROFILES = BUILTIN_PROFILES

return M
