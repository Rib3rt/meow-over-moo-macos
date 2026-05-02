local punishMap = require("ai_tournament.punish_map")
local strategicInterpreter = require("ai_tournament.strategic_interpreter")
local strategicQuestions = require("ai_tournament.strategic_questions")

local M = {}

local DEFAULT_GRID_SIZE = 8

local INTENT_ROLE_DEMAND = {
    supported_vanguard = {
        blocker = 0.45,
        antiGround = 0.35,
        mobility = 0.25,
        commandantPressure = 0.25
    },
    lane_control = {
        blocker = 0.40,
        antiGround = 0.30,
        mobility = 0.30,
        siege = 0.20
    },
    ranged_battery = {
        siege = 0.55,
        blocker = 0.35,
        commandantPressure = 0.25,
        mobility = 0.20
    },
    flank_pressure = {
        mobility = 0.55,
        commandantPressure = 0.35,
        antiGround = 0.25
    },
    choke_lock = {
        blocker = 0.55,
        antiGround = 0.25,
        siege = 0.25,
        commandantDefense = 0.15
    },
    counter_punch = {
        antiGround = 0.55,
        antiFlying = 0.25,
        mobility = 0.35,
        commandantDefense = 0.25
    },
    active_defense = {
        commandantDefense = 0.45,
        blocker = 0.35,
        antiGround = 0.35,
        antiFlying = 0.25
    }
}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function clamp(value, minValue, maxValue)
    local v = num(value, 0)
    if minValue and v < minValue then
        v = minValue
    end
    if maxValue and v > maxValue then
        v = maxValue
    end
    return v
end

local function copyMap(values)
    local out = {}
    for key, value in pairs(values or {}) do
        out[key] = value
    end
    return out
end

local function cfgValue(ctx, key, fallback)
    return num(ctx and ctx.cfg and ctx.cfg[key], fallback or 0)
end

local function cfgTable(ai, ctx)
    if ctx and type(ctx.cfg) == "table" then
        return ctx.cfg
    end
    if ai and ai.getTournamentConfig then
        local ok, value = pcall(ai.getTournamentConfig, ai)
        if ok and type(value) == "table" then
            return value
        end
    end
    return nil
end

local function normalizedReference(value)
    if value == nil then
        return nil
    end
    local reference = tostring(value)
    if reference == "" then
        return nil
    end
    return string.lower(reference)
end

local function earlyPhaseReference(ai, state, ctx)
    local reference = normalizedReference(ctx and (ctx.earlyPhaseReference or ctx.aiReference))
    if reference then
        return reference
    end

    reference = normalizedReference(ai and ai.aiReference)
    if reference then
        return reference
    end

    if ai and ai.getEffectiveAiReference then
        local ok, value = pcall(ai.getEffectiveAiReference, ai, state, {
            factionId = ctx and ctx.aiPlayer
        })
        reference = ok and normalizedReference(value) or nil
        if reference then
            return reference
        end
    end

    return "base"
end

local function earlyPhaseTurnMax(ai, state, ctx)
    local cfg = cfgTable(ai, ctx)
    local fallback = num(cfg and cfg.EARLY_PHASE_TURN_MAX, cfgValue(ctx, "EARLY_PHASE_TURN_MAX", 10))
    local reference = earlyPhaseReference(ai, state, ctx)
    local byReference = cfg and cfg.EARLY_PHASE_TURN_MAX_BY_REFERENCE
    local configured = type(byReference) == "table" and byReference[reference] or nil
    local turnMax = math.floor(num(configured, fallback))
    if turnMax < 0 then
        turnMax = 0
    end
    return turnMax, reference
end

local function gridSize(state)
    return num(state and state.gridSize, num(GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE, DEFAULT_GRID_SIZE))
end

local function inBounds(state, row, col)
    local size = gridSize(state)
    return row >= 1 and row <= size and col >= 1 and col <= size
end

local function manhattan(a, b)
    if not a or not b then
        return 99
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function sign(value)
    if value > 0 then
        return 1
    end
    if value < 0 then
        return -1
    end
    return 0
end

local function getOpponent(ai, playerId)
    if ai and ai.getOpponentPlayer then
        return ai:getOpponentPlayer(playerId)
    end
    return playerId == 1 and 2 or 1
end

local function isHubUnit(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isHubUnit then
        local ok, value = pcall(ai.isHubUnit, ai, unit)
        if ok then
            return value == true
        end
    end
    return unit.name == "Commandant"
end

local function isObstacleUnit(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isObstacleUnit then
        local ok, value = pcall(ai.isObstacleUnit, ai, unit)
        if ok then
            return value == true
        end
    end
    return unit.name == "Rock" or unit.player == 0
end

local function getUnitAt(ai, state, row, col)
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.row == row and unit.col == col then
            return unit
        end
    end
    for _, rock in ipairs((state and state.neutralBuildings) or {}) do
        if rock and rock.row == row and rock.col == col then
            return {
                name = rock.name or "Rock",
                player = 0,
                row = row,
                col = col,
                currentHp = rock.currentHp or rock.hp or 5,
                startingHp = rock.startingHp or rock.hp or 5
            }
        end
    end
    return nil
end

local function getUnitsForPlayer(ai, state, playerId)
    local result = {}
    for _, unit in ipairs((state and state.units) or {}) do
        if unit
            and unit.player == playerId
            and not isHubUnit(ai, unit)
            and not isObstacleUnit(ai, unit) then
            result[#result + 1] = unit
        end
    end
    return result
end

local function supplyCountForPlayer(state, playerId, ctx)
    if ctx and ctx.supply then
        if playerId == ctx.aiPlayer and ctx.supply.own then
            return num(ctx.supply.own.count, 0)
        end
        if playerId == ctx.enemyPlayer and ctx.supply.enemy then
            return num(ctx.supply.enemy.count, 0)
        end
    end
    local list = state and state.supply and state.supply[playerId] or {}
    return #list
end

local function supplyByNameForPlayer(state, playerId, ctx)
    local byName = {}
    local snapshot = nil
    if ctx and ctx.supply then
        if playerId == ctx.aiPlayer then
            snapshot = ctx.supply.own
        elseif playerId == ctx.enemyPlayer then
            snapshot = ctx.supply.enemy
        end
    end
    if snapshot and snapshot.byName then
        return snapshot.byName
    end
    for _, unit in ipairs((state and state.supply and state.supply[playerId]) or {}) do
        local name = tostring(unit and unit.name or "unknown")
        byName[name] = (byName[name] or 0) + 1
    end
    return byName
end

local function resolveHub(ai, state, playerId, enemyOfPlayer)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if hub then
        return hub, false
    end

    local ruler = ai and ai.gameRuler
    local rulerHub = ruler and ruler.commandHubPositions and ruler.commandHubPositions[playerId]
    if rulerHub then
        return {
            row = rulerHub.row,
            col = rulerHub.col
        }, false
    end

    if enemyOfPlayer then
        local size = gridSize(state)
        return {
            row = clamp(size + 1 - num(enemyOfPlayer.row, 1), 1, size),
            col = clamp(size + 1 - num(enemyOfPlayer.col, 1), 1, size),
            virtual = true
        }, true
    end

    return nil, false
end

function M.detectPhase(ai, state, ctx)
    local turn = num(
        state and (state.currentTurn or state.turnNumber),
        num(GAME and GAME.CURRENT and GAME.CURRENT.TURN, 1)
    )
    local earlyMax, earlyReference = earlyPhaseTurnMax(ai, state, ctx)
    local p1Supply = supplyCountForPlayer(state, 1, ctx)
    local p2Supply = supplyCountForPlayer(state, 2, ctx)

    if p1Supply <= 0 or p2Supply <= 0 then
        local reason = "supply_empty"
        if p1Supply <= 0 and p2Supply > 0 then
            reason = "supply_empty_p1"
        elseif p2Supply <= 0 and p1Supply > 0 then
            reason = "supply_empty_p2"
        elseif p1Supply <= 0 and p2Supply <= 0 then
            reason = "supply_empty_both"
        end
        return {
            name = "endgame",
            turn = turn,
            early = false,
            mid = false,
            endgame = true,
            reason = reason,
            earlyMax = earlyMax,
            earlyReference = earlyReference,
            supply = {
                [1] = p1Supply,
                [2] = p2Supply
            }
        }
    end

    if turn <= earlyMax then
        return {
            name = "early",
            turn = turn,
            early = true,
            mid = false,
            endgame = false,
            reason = "turn_1_" .. tostring(earlyMax),
            earlyMax = earlyMax,
            earlyReference = earlyReference,
            supply = {
                [1] = p1Supply,
                [2] = p2Supply
            }
        }
    end

    return {
        name = "mid",
        turn = turn,
        early = false,
        mid = true,
        endgame = false,
        reason = "after_early_" .. tostring(earlyMax),
        earlyMax = earlyMax,
        earlyReference = earlyReference,
        supply = {
            [1] = p1Supply,
            [2] = p2Supply
        }
    }
end

local function laneAxis(ownHub, enemyHub)
    if not ownHub or not enemyHub then
        return "col"
    end
    local rowDelta = math.abs(num(enemyHub.row, 0) - num(ownHub.row, 0))
    local colDelta = math.abs(num(enemyHub.col, 0) - num(ownHub.col, 0))
    return rowDelta >= colDelta and "col" or "row"
end

local function laneNameForValue(value, size)
    local third = size / 3
    if value <= third then
        return "left"
    end
    if value <= third * 2 then
        return "center"
    end
    return "right"
end

local function laneCenter(name, size)
    if name == "left" then
        return math.max(1, math.floor((size + 2) / 6))
    end
    if name == "right" then
        return math.min(size, math.ceil(size - ((size + 2) / 6)))
    end
    return math.floor((size + 1) / 2)
end

local function laneValueForCell(axis, cell)
    if axis == "row" then
        return num(cell and cell.row, 0)
    end
    return num(cell and cell.col, 0)
end

local function laneNameForCell(axis, cell, size)
    return laneNameForValue(laneValueForCell(axis, cell), size)
end

local function laneDistance(a, b)
    if a == b then
        return 0
    end
    if a == "center" or b == "center" then
        return 1
    end
    return 2
end

local function countLaneObstacles(ai, state, axis, laneName)
    local size = gridSize(state)
    local count = 0
    local function visit(row, col)
        local unit = getUnitAt(ai, state, row, col)
        if unit and isObstacleUnit(ai, unit) then
            count = count + 1
        end
    end

    for row = 1, size do
        for col = 1, size do
            if laneNameForCell(axis, {row = row, col = col}, size) == laneName then
                visit(row, col)
            end
        end
    end
    return count
end

local function closestUnitToTarget(units, target)
    local best = nil
    for _, unit in ipairs(units or {}) do
        local d = manhattan(unit, target)
        if not best
            or d < best.distance
            or (d == best.distance and tostring(unit.name or "") < tostring(best.unit.name or "")) then
            best = {
                unit = unit,
                distance = d
            }
        end
    end
    return best
end

local function enemyPressureFeatures(ai, state, playerId, enemyPlayer)
    local ownHub = state and state.commandHubs and state.commandHubs[playerId]
    local enemyHub = state and state.commandHubs and state.commandHubs[enemyPlayer]
    local enemies = getUnitsForPlayer(ai, state, enemyPlayer)
    local closest = closestUnitToTarget(enemies, ownHub)
    local enemyRanged = 0
    local exposedVanguard = nil

    for _, unit in ipairs(enemies) do
        local range = num(unit.atkRange, 1)
        if range > 1 or unit.name == "Cloudstriker" or unit.name == "Artillery" then
            enemyRanged = enemyRanged + 1
        end
        local ownSupport = 0
        for _, ally in ipairs(enemies) do
            if ally ~= unit and manhattan(ally, unit) <= 2 then
                ownSupport = ownSupport + 1
            end
        end
        if enemyHub and ownHub and manhattan(unit, ownHub) < manhattan(unit, enemyHub) and ownSupport == 0 then
            if not exposedVanguard or manhattan(unit, ownHub) < manhattan(exposedVanguard, ownHub) then
                exposedVanguard = unit
            end
        end
    end

    return {
        closest = closest,
        enemyRanged = enemyRanged,
        exposedVanguard = exposedVanguard
    }
end

local function unitRoleKinds(unitName, ctx)
    local vector = (ctx and ctx.cfg and ctx.cfg.SUPPLY_ROLE_VECTOR and ctx.cfg.SUPPLY_ROLE_VECTOR[unitName]) or {}
    local slowSiege = num(vector.siege, 0) >= cfgValue(ctx, "EARLY_SLOW_SIEGE_MIN_SIEGE", 0.75)
        and num(vector.mobility, 0) <= cfgValue(ctx, "EARLY_SLOW_SIEGE_MAX_MOBILITY", 0.25)
    return {
        frontline = num(vector.blocker, 0) + num(vector.commandantDefense, 0),
        damage = num(vector.antiGround, 0) + num(vector.commandantPressure, 0),
        ranged = num(vector.siege, 0),
        mobility = num(vector.mobility, 0),
        support = num(vector.repair, 0),
        slowSiege = slowSiege and 1 or 0
    }
end

local function isSlowSiegeUnit(unitName, ctx)
    return unitRoleKinds(unitName, ctx).slowSiege > 0
end

local function countSupplyKinds(state, playerId, ctx)
    local byName = supplyByNameForPlayer(state, playerId, ctx)
    local counts = {
        ranged = 0,
        frontline = 0,
        mobile = 0,
        support = 0,
        damage = 0,
        slowSiege = 0
    }
    for name, count in pairs(byName) do
        local roles = unitRoleKinds(name, ctx)
        if roles.ranged > 0.5 then
            counts.ranged = counts.ranged + count
        end
        if roles.frontline > 0.5 then
            counts.frontline = counts.frontline + count
        end
        if roles.mobility > 0.5 then
            counts.mobile = counts.mobile + count
        end
        if roles.support > 0.5 then
            counts.support = counts.support + count
        end
        if roles.damage > 0.5 then
            counts.damage = counts.damage + count
        end
        if roles.slowSiege > 0 then
            counts.slowSiege = counts.slowSiege + count
        end
    end
    return counts
end

local function addCell(list, seen, row, col, state)
    if not inBounds(state, row, col) then
        return
    end
    local key = tostring(row) .. "," .. tostring(col)
    if seen[key] then
        return
    end
    seen[key] = true
    list[#list + 1] = {row = row, col = col}
end

local function buildPlanCells(state, ownHub, enemyHub, axis, focalLane, vanguard)
    local supportCells = {}
    local vanguardCells = {}
    local denyCells = {}
    local avoidCells = {}
    local seenSupport = {}
    local seenVanguard = {}
    local seenDeny = {}
    local seenAvoid = {}
    local size = gridSize(state)
    local laneCenterValue = laneCenter(focalLane, size)
    local rowStep = sign(num(enemyHub and enemyHub.row, 0) - num(ownHub and ownHub.row, 0))
    local colStep = sign(num(enemyHub and enemyHub.col, 0) - num(ownHub and ownHub.col, 0))
    if rowStep == 0 and colStep == 0 then
        rowStep = 1
    end

    local function laneCell(forward)
        local row = num(ownHub and ownHub.row, 1) + (rowStep * forward)
        local col = num(ownHub and ownHub.col, 1) + (colStep * forward)
        if axis == "col" then
            col = laneCenterValue
        else
            row = laneCenterValue
        end
        return row, col
    end

    for stepIndex = 1, 4 do
        local row, col = laneCell(stepIndex)
        addCell(vanguardCells, seenVanguard, row, col, state)
        addCell(supportCells, seenSupport, row - rowStep, col, state)
        addCell(supportCells, seenSupport, row, col - colStep, state)
        addCell(supportCells, seenSupport, row, col + colStep, state)
    end

    if vanguard then
        for dr = -2, 2 do
            for dc = -2, 2 do
                if math.abs(dr) + math.abs(dc) <= 2 then
                    addCell(supportCells, seenSupport, num(vanguard.row, 0) + dr, num(vanguard.col, 0) + dc, state)
                end
            end
        end
    end

    local enemyRow = num(enemyHub and enemyHub.row, size)
    local enemyCol = num(enemyHub and enemyHub.col, size)
    for dr = -2, 2 do
        for dc = -2, 2 do
            if math.abs(dr) + math.abs(dc) <= 2 then
                addCell(denyCells, seenDeny, enemyRow + dr, enemyCol + dc, state)
            end
        end
    end

    for dr = -1, 1 do
        for dc = -1, 1 do
            if math.abs(dr) + math.abs(dc) <= 1 then
                addCell(avoidCells, seenAvoid, num(ownHub and ownHub.row, 1) + dr, num(ownHub and ownHub.col, 1) + dc, state)
            end
        end
    end

    return vanguardCells, supportCells, denyCells, avoidCells
end

local function chooseOpeningIntent(state, playerId, ctx, axis, ownLane, enemyLane)
    local supplyKinds = countSupplyKinds(state, playerId, ctx)
    local obstaclePressure = countLaneObstacles(ctx and ctx.selfAI, state, axis, ownLane)
        + countLaneObstacles(ctx and ctx.selfAI, state, axis, enemyLane)
    local centerObstaclePressure = countLaneObstacles(ctx and ctx.selfAI, state, axis, "center")
    local laneOffset = laneDistance(ownLane, enemyLane)
    local reasons = {}
    local candidates = {
        {
            intent = "supported_vanguard",
            score = 0.36
                + math.min(0.18, supplyKinds.frontline * 0.08)
                + math.min(0.14, supplyKinds.damage * 0.06),
            reason = "board_supports_vanguard"
        },
        {
            intent = "lane_control",
            score = 0.32
                + (laneOffset * 0.14)
                + (obstaclePressure <= 3 and 0.08 or 0),
            reason = ownLane ~= enemyLane and "hub_lanes_are_offset" or "contest_shared_lane"
        },
        {
            intent = "ranged_battery",
            score = 0.24
                + math.min(0.20, math.max(0, supplyKinds.ranged - supplyKinds.slowSiege) * 0.10)
                + math.min(0.10, supplyKinds.frontline * 0.05)
                - math.min(0.18, obstaclePressure * 0.035)
                - math.min(0.22, supplyKinds.slowSiege * 0.11),
            reason = "reserve_has_ranged_plus_screen"
        },
        {
            intent = "flank_pressure",
            score = 0.24
                + math.min(0.24, supplyKinds.mobile * 0.08)
                + (laneOffset * 0.08)
                + math.min(0.12, centerObstaclePressure * 0.03),
            reason = "mobile_reserve_can_widen_pressure"
        },
        {
            intent = "choke_lock",
            score = 0.24
                + math.min(0.42, obstaclePressure * 0.09)
                + math.min(0.12, supplyKinds.frontline * 0.04),
            reason = "rocks_create_choke_pressure"
        }
    }

    table.sort(candidates, function(a, b)
        if a.score == b.score then
            return tostring(a.intent) < tostring(b.intent)
        end
        return a.score > b.score
    end)

    local selected = candidates[1] or {intent = "supported_vanguard", reason = "default_supported_vanguard"}
    reasons[#reasons + 1] = selected.reason
    reasons[#reasons + 1] = "opening_intent_scored_from_board"

    return selected.intent, reasons
end

local function chooseResponseIntent(ai, state, playerId, enemyPlayer, ctx, axis, ownLane, enemyLane, pressure)
    pressure = pressure or enemyPressureFeatures(ai, state, playerId, enemyPlayer)
    local supplyKinds = countSupplyKinds(state, playerId, ctx)
    local reasons = {}
    local intent = "lane_control"
    local responseKind = "contest"

    if pressure.exposedVanguard then
        intent = "counter_punch"
        responseKind = "punish_overextension"
        reasons[#reasons + 1] = "enemy_vanguard_overextended"
    elseif pressure.enemyRanged > 0 and supplyKinds.frontline > 0 then
        intent = "active_defense"
        responseKind = "screen_ranged_pressure"
        reasons[#reasons + 1] = "enemy_ranged_pressure_detected"
    elseif countLaneObstacles(ai, state, axis, ownLane) + countLaneObstacles(ai, state, axis, enemyLane) >= 4 then
        intent = "choke_lock"
        responseKind = "block_choke"
        reasons[#reasons + 1] = "contest_choke_lane"
    elseif supplyKinds.mobile > 0 and laneDistance(ownLane, enemyLane) <= 1 then
        intent = "flank_pressure"
        responseKind = "flank_response"
        reasons[#reasons + 1] = "use_mobility_to_avoid_mirror"
    else
        reasons[#reasons + 1] = "contest_enemy_opening_lane"
    end

    return intent, responseKind, pressure, reasons
end

local function selectEarlyRole(ai, state, playerId, enemyPlayer, ctx)
    local pressure = enemyPressureFeatures(ai, state, playerId, enemyPlayer)
    local enemyUnits = getUnitsForPlayer(ai, state, enemyPlayer)
    local reasons = {}
    local pressureScore = 0

    if #enemyUnits <= 0 then
        reasons[#reasons + 1] = "enemy_has_no_board_presence"
        reasons[#reasons + 1] = "role_from_board_initiative"
        return "opening", pressure, pressureScore, reasons
    end

    if pressure.exposedVanguard then
        pressureScore = pressureScore + cfgValue(ctx, "EARLY_RESPONSE_EXPOSED_VANGUARD_SCORE", 1.65)
        reasons[#reasons + 1] = "enemy_vanguard_overextended"
    end

    local closestDistance = num(pressure.closest and pressure.closest.distance, 99)
    local pressureDistance = cfgValue(ctx, "EARLY_RESPONSE_PRESSURE_DISTANCE", 4)
    if closestDistance <= pressureDistance then
        pressureScore = pressureScore
            + ((pressureDistance - closestDistance + 1)
                * cfgValue(ctx, "EARLY_RESPONSE_NEAR_HUB_SCORE", 0.42))
        reasons[#reasons + 1] = "enemy_near_own_commandant"
    end

    if closestDistance <= cfgValue(ctx, "EARLY_RESPONSE_APPROACH_DISTANCE", 6) then
        pressureScore = pressureScore + cfgValue(ctx, "EARLY_RESPONSE_APPROACH_SCORE", 0.60)
        reasons[#reasons + 1] = "enemy_contesting_approach"
    end

    if pressure.enemyRanged > 0 and closestDistance <= pressureDistance + 2 then
        pressureScore = pressureScore
            + math.min(
                pressure.enemyRanged * cfgValue(ctx, "EARLY_RESPONSE_RANGED_PRESSURE_SCORE", 0.55),
                cfgValue(ctx, "EARLY_RESPONSE_RANGED_PRESSURE_MAX", 1.10)
            )
        reasons[#reasons + 1] = "enemy_ranged_pressure_detected"
    end

    if pressureScore >= cfgValue(ctx, "EARLY_RESPONSE_PRESSURE_SCORE", 1.0) then
        reasons[#reasons + 1] = "role_from_board_pressure"
        return "response", pressure, pressureScore, reasons
    end

    reasons[#reasons + 1] = "enemy_pressure_below_response_threshold"
    reasons[#reasons + 1] = "role_from_board_initiative"
    return "opening", pressure, pressureScore, reasons
end

function M.build(ai, state, ctx)
    local playerId = ctx and ctx.aiPlayer or (ai and ai.getFactionId and ai:getFactionId()) or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or getOpponent(ai, playerId)
    local phase = ctx and ctx.phase or M.detectPhase(ai, state, ctx)

    if not (phase and phase.early) then
        return {
            active = false,
            phase = phase and phase.name or "unknown",
            reason = phase and phase.reason or "not_early"
        }
    end

    local ownHub = resolveHub(ai, state, playerId, nil)
    local enemyHub, virtualEnemyHub = resolveHub(ai, state, enemyPlayer, ownHub)
    if not (ownHub and enemyHub) then
        return {
            active = false,
            phase = phase.name,
            reason = "missing_commandant"
        }
    end

    local axis = laneAxis(ownHub, enemyHub)
    local size = gridSize(state)
    local ownLane = laneNameForCell(axis, ownHub, size)
    local enemyLane = laneNameForCell(axis, enemyHub, size)
    local focalLane = laneDistance("center", enemyLane) <= laneDistance(ownLane, enemyLane) and "center" or ownLane
    local ownUnits = getUnitsForPlayer(ai, state, playerId)
    local enemyUnits = getUnitsForPlayer(ai, state, enemyPlayer)
    local vanguard = closestUnitToTarget(ownUnits, enemyHub)
    local intent = nil
    local role, pressure, rolePressureScore, roleReasons = selectEarlyRole(ai, state, playerId, enemyPlayer, ctx)
    local responseKind = nil
    local reasons = {}

    if role == "opening" then
        intent, reasons = chooseOpeningIntent(state, playerId, ctx, axis, ownLane, enemyLane)
    else
        intent, responseKind, pressure, reasons =
            chooseResponseIntent(ai, state, playerId, enemyPlayer, ctx, axis, ownLane, enemyLane, pressure)
    end

    for _, reason in ipairs(roleReasons or {}) do
        reasons[#reasons + 1] = reason
    end

    if virtualEnemyHub then
        reasons[#reasons + 1] = "virtual_enemy_commandant_for_setup"
    end

    local vanguardCells, supportCells, denyCells, avoidCells =
        buildPlanCells(state, ownHub, enemyHub, axis, focalLane, vanguard and vanguard.unit or nil)
    local roleDemand = copyMap(INTENT_ROLE_DEMAND[intent] or INTENT_ROLE_DEMAND.supported_vanguard)

    local confidence = 0.48
        + math.min(0.18, #ownUnits * 0.04)
        + math.min(0.16, supplyCountForPlayer(state, playerId, ctx) * 0.02)
        + (#reasons > 0 and 0.10 or 0)
    if role == "response" and pressure and pressure.exposedVanguard then
        confidence = confidence + 0.10
    end

    return {
        active = true,
        phase = phase.name,
        role = role,
        intent = intent,
        intentId = intent,
        focalLane = focalLane,
        supportLane = ownLane == focalLane and enemyLane or ownLane,
        ownLane = ownLane,
        enemyLane = enemyLane,
        laneAxis = axis,
        desiredRoles = roleDemand,
        roleDemand = roleDemand,
        vanguardUnitIds = vanguard and {
            tostring(vanguard.unit.name or "?") .. "@" .. tostring(vanguard.unit.row) .. "," .. tostring(vanguard.unit.col)
        } or {},
        vanguardCells = vanguardCells,
        supportCells = supportCells,
        denyCells = denyCells,
        avoidCells = avoidCells,
        pressureTargets = pressure and pressure.exposedVanguard and {
            {
                row = pressure.exposedVanguard.row,
                col = pressure.exposedVanguard.col,
                name = pressure.exposedVanguard.name,
                reason = "exposed_vanguard"
            }
        } or {
            {
                row = enemyHub.row,
                col = enemyHub.col,
                name = "Commandant",
                reason = "enemy_commandant"
            }
        },
        responseKind = responseKind,
        redResponseKind = responseKind,
        confidence = clamp(confidence, 0.0, 1.0),
        reasons = reasons,
        features = {
            ownUnitCount = #ownUnits,
            enemyUnitCount = #enemyUnits,
            ownSupplyCount = supplyCountForPlayer(state, playerId, ctx),
            enemySupplyCount = supplyCountForPlayer(state, enemyPlayer, ctx),
            ownLane = ownLane,
            enemyLane = enemyLane,
            laneAxis = axis,
            rolePressureScore = rolePressureScore,
            virtualEnemyHub = virtualEnemyHub == true
        }
    }
end

local function cellListMinDistance(cells, row, col)
    local best = 99
    for _, cell in ipairs(cells or {}) do
        local d = manhattan(cell, {row = row, col = col})
        if d < best then
            best = d
        end
    end
    return best
end

local function roleFitScore(unitName, plan, ctx)
    local vector = (ctx and ctx.cfg and ctx.cfg.SUPPLY_ROLE_VECTOR and ctx.cfg.SUPPLY_ROLE_VECTOR[unitName]) or {}
    local total = 0
    for role, demand in pairs((plan and plan.roleDemand) or {}) do
        total = total + num(vector[role], 0) * num(demand, 0)
    end
    return total
end

local function forwardProgress(ownHub, enemyHub, fromCell, toCell)
    if not (ownHub and enemyHub and toCell) then
        return 0
    end
    local fromDistance = manhattan(fromCell or ownHub, enemyHub)
    local toDistance = manhattan(toCell, enemyHub)
    return fromDistance - toDistance
end

local function deployedUnitForAnalysis(ai, state, deployAction, playerId, target)
    local afterState = nil
    if ai and ai.applySupplyDeploymentForPlayer then
        local ok, projected = pcall(ai.applySupplyDeploymentForPlayer, ai, state, deployAction, playerId, {
            scoreDeployments = false
        })
        if ok and projected then
            afterState = projected
        end
    end
    local deployed = afterState and getUnitAt(ai, afterState, target.row, target.col) or nil
    if not deployed then
        deployed = {
            name = deployAction.unitName,
            player = playerId,
            row = target.row,
            col = target.col,
            currentHp = deployAction.currentHp or deployAction.startingHp or 3,
            startingHp = deployAction.startingHp or deployAction.currentHp or 3
        }
    end
    return afterState or state, deployed
end

local function strategicFreeCell(ai, state, ctx, row, col)
    if not (punishMap and punishMap.findStrategicFreeCells and state and row and col) then
        return nil
    end
    ctx._earlyStrategicFreeCells = ctx._earlyStrategicFreeCells or {}
    local cache = ctx._earlyStrategicFreeCells
    if cache.state ~= state then
        cache.state = state
        cache.strategic = punishMap.findStrategicFreeCells(state, ai, ctx, {maxCells = 32})
    end
    local strategic = cache.strategic
    return strategic and strategic.byKey and strategic.byKey[tostring(row) .. "," .. tostring(col)] or nil
end

local function strategicPosition(ai, state, ctx)
    if not (strategicInterpreter and strategicInterpreter.interpret and state and ctx) then
        return nil
    end
    ctx._earlyStrategicPosition = ctx._earlyStrategicPosition or {}
    local cache = ctx._earlyStrategicPosition
    if cache.state ~= state then
        cache.state = state
        cache.position = strategicInterpreter.interpret(state, ai, ctx)
    end
    return cache.position
end

local function strategicQuestionPurpose(plan, actionKind)
    local role = tostring(plan and plan.role or "")
    local intent = tostring(plan and (plan.intentId or plan.intent) or "")
    if actionKind == "deploy" then
        return "deploy"
    end
    if role == "response" then
        return "contain"
    end
    if intent == "flank_pressure" or intent == "ranged_battery" then
        return "pressure"
    end
    if intent == "choke_lock" or intent == "counter_punch" then
        return "contain"
    end
    if intent == "active_defense" then
        return "support"
    end
    return "expand"
end

local function strategicCellFor(ai, state, ctx, row, col)
    local position = strategicPosition(ai, state, ctx)
    return position and position.byKey and position.byKey[tostring(row) .. "," .. tostring(col)] or nil
end

local function applyStrategicQuestionBias(result, ai, state, ctx, plan, row, col, actionKind, opts)
    if not (result and strategicQuestions and strategicQuestions.scoreCell and row and col) then
        return
    end
    opts = opts or {}
    local cell = strategicCellFor(ai, state, ctx, row, col)
    if not cell then
        return
    end
    local purpose = opts.purpose or strategicQuestionPurpose(plan, actionKind)
    local questionOpts = {}
    for key, value in pairs(opts) do
        questionOpts[key] = value
    end
    questionOpts.ctx = ctx
    local scored = strategicQuestions.scoreCell(cell, purpose, questionOpts)
    local defaultScale = actionKind == "deploy" and 0.42 or 0.35
    if plan and plan.role == "response" then
        defaultScale = defaultScale * 0.45
    end
    local scaleKey = actionKind == "deploy"
        and "EARLY_STRATEGIC_QUESTION_DEPLOY_SCALE"
        or "EARLY_STRATEGIC_QUESTION_MOVE_SCALE"
    local maxKey = actionKind == "deploy"
        and "EARLY_STRATEGIC_QUESTION_DEPLOY_MAX"
        or "EARLY_STRATEGIC_QUESTION_MOVE_MAX"
    local scale = cfgValue(ctx, scaleKey, defaultScale)
    local maxBonus = cfgValue(ctx, maxKey, actionKind == "deploy" and 180 or 140)
    local bonus = clamp(num(scored and scored.value, 0) * scale, -maxBonus, maxBonus)
    result.strategicQuestion = scored
    result.strategicQuestionPurpose = purpose
    result.strategicQuestionCell = cell
    result.strategicPersonality = scored and scored.personality
    result.reasons[#result.reasons + 1] = "early_strategic_question_considered_" .. tostring(purpose)
    if bonus ~= 0 then
        local targetField = opts.targetField or "cellFit"
        result[targetField] = (result[targetField] or 0) + bonus
        result.reasons[#result.reasons + 1] = "early_strategic_question_" .. tostring(purpose)
        for _, item in ipairs(scored.reasons or {}) do
            result.reasons[#result.reasons + 1] = tostring(item.reason or item)
        end
    end
end

function M.scoreDeployAction(ai, state, deployAction, playerId, ctx, plan)
    local activePlan = plan or (ctx and ctx.earlyPlan)
    local result = {
        value = 0,
        roleFit = 0,
        cellFit = 0,
        reasons = {}
    }
    if not (activePlan and activePlan.active and deployAction and deployAction.type == "supply_deploy") then
        return result
    end

    local cfg = ctx and ctx.cfg or {}
    local ownHub = state and state.commandHubs and state.commandHubs[playerId]
    local enemyHub = state and state.commandHubs and state.commandHubs[getOpponent(ai, playerId)]
    local target = deployAction.target or {}
    local unitName = tostring(deployAction.unitName or deployAction.unitType or "")
    local roleWeight = cfgValue(ctx, "EARLY_PLAN_DEPLOY_ROLE_WEIGHT", 240)
    local cellWeight = cfgValue(ctx, "EARLY_PLAN_DEPLOY_CELL_WEIGHT", 90)
    local maxValue = cfgValue(ctx, "EARLY_PLAN_DEPLOY_BONUS_MAX", 420)
    local slowSiege = isSlowSiegeUnit(unitName, ctx)

    result.roleFit = roleFitScore(unitName, activePlan, ctx) * roleWeight
    if slowSiege then
        result.roleFit = result.roleFit * cfgValue(ctx, "EARLY_SLOW_SIEGE_ROLE_FIT_SCALE", 0.45)
        result.reasons[#result.reasons + 1] = "early_slow_siege_support_role"
    end
    if result.roleFit > 0 then
        result.reasons[#result.reasons + 1] = "early_role_fit"
    end

    local lane = laneNameForCell(activePlan.laneAxis or "col", target, gridSize(state))
    local laneFit = 2 - laneDistance(lane, activePlan.focalLane or lane)
    result.cellFit = result.cellFit + (laneFit * cellWeight)

    local supportDistance = cellListMinDistance(activePlan.supportCells, target.row, target.col)
    if supportDistance <= 1 then
        result.cellFit = result.cellFit + (cellWeight * 1.8)
        result.reasons[#result.reasons + 1] = "early_support_cell"
    elseif supportDistance == 2 then
        result.cellFit = result.cellFit + cellWeight
        result.reasons[#result.reasons + 1] = "early_near_support_cell"
    end

    local denyDistance = cellListMinDistance(activePlan.denyCells, target.row, target.col)
    if denyDistance <= 1 then
        result.cellFit = result.cellFit + (cellWeight * 1.2)
        result.reasons[#result.reasons + 1] = "early_deny_cell"
    end

    local avoidDistance = cellListMinDistance(activePlan.avoidCells, target.row, target.col)
    if avoidDistance <= 0 then
        result.cellFit = result.cellFit - (cellWeight * 2.0)
        result.reasons[#result.reasons + 1] = "early_avoid_home_clump"
    end

    local progress = forwardProgress(ownHub, enemyHub, ownHub, target)
    if progress > 0 then
        result.cellFit = result.cellFit + math.min(progress * cellWeight * 0.35, cellWeight * 1.5)
        result.reasons[#result.reasons + 1] = "early_forward_deploy"
    end

    if slowSiege then
        result.cellFit = result.cellFit - cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_TEMPO_PENALTY", 360)
        if progress > 1 then
            result.cellFit = result.cellFit
                - ((progress - 1) * cfgValue(ctx, "EARLY_SLOW_SIEGE_FORWARD_STEP_PENALTY", 140))
            result.reasons[#result.reasons + 1] = "early_slow_siege_not_vanguard"
        end
        if denyDistance <= 2 then
            result.cellFit = result.cellFit - cfgValue(ctx, "EARLY_SLOW_SIEGE_DANGER_ZONE_PENALTY", 260)
            result.reasons[#result.reasons + 1] = "early_slow_siege_not_deny_piece"
        end
        if supportDistance > 2 then
            result.cellFit = result.cellFit - cfgValue(ctx, "EARLY_SLOW_SIEGE_UNSUPPORTED_PENALTY", 180)
            result.reasons[#result.reasons + 1] = "early_slow_siege_needs_screen"
        end
    end

    if punishMap and punishMap.analyzeCell and target.row and target.col then
        local strategicCell = nil
        if activePlan.role ~= "response" then
            strategicCell = strategicFreeCell(ai, state, ctx, target.row, target.col)
        end
        result.strategicFreeCell = strategicCell
        applyStrategicQuestionBias(result, ai, state, ctx, activePlan, target.row, target.col, "deploy")

        local analysisState, deployed = deployedUnitForAnalysis(ai, state, deployAction, playerId, target)
        local analysis = punishMap.analyzeCell(analysisState, ai, ctx, deployed, target)
        result.punishMap = analysis
        if analysis and analysis.enemyBestReply then
            if analysis.covered == true then
                local tradeBonus = math.max(0, num(analysis.tradeNet, 0))
                    * cfgValue(ctx, "EARLY_PUNISH_MAP_DEPLOY_TRADE_NET_WEIGHT", 24)
                result.cellFit = result.cellFit
                    + cfgValue(ctx, "EARLY_PUNISH_MAP_DEPLOY_COVERED_BONUS", 180)
                    + math.min(tradeBonus, cellWeight * 2.0)
                result.reasons[#result.reasons + 1] = "early_punish_map_deploy_covered"
            else
                local penalty = cfgValue(ctx, "EARLY_PUNISH_MAP_DEPLOY_UNCOVERED_PENALTY", 420)
                if analysis.enemyBestReply.lethal then
                    penalty = penalty + cfgValue(ctx, "EARLY_PUNISH_MAP_DEPLOY_LETHAL_EXTRA_PENALTY", 320)
                end
                if unitName == "Healer" then
                    penalty = penalty + cfgValue(ctx, "EARLY_PUNISH_MAP_HEALER_EXPOSURE_PENALTY", 520)
                end
                result.cellFit = result.cellFit - penalty
                result.reasons[#result.reasons + 1] = "early_punish_map_deploy_uncovered"
            end
        elseif supportDistance <= 2 or denyDistance <= 2 then
            result.cellFit = result.cellFit + cfgValue(ctx, "EARLY_PUNISH_MAP_DEPLOY_SAFE_POSITION_BONUS", 90)
            result.reasons[#result.reasons + 1] = "early_punish_map_deploy_safe_position"
        end
    end

    result.value = clamp(result.roleFit + result.cellFit, -maxValue, maxValue)
    return result
end

local function factionAttackImpact(ai, state, candidate, playerId)
    local impact = {
        factionAttackCount = 0,
        damagingFactionAttackCount = 0,
        killCount = 0,
        damage = 0,
        commandantDamage = 0
    }
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action and action.type == "attack" and action.target then
            local target = getUnitAt(ai, state, action.target.row, action.target.col)
            local attacker = getUnitAt(ai, state, action.unit and action.unit.row, action.unit and action.unit.col)
            if target and attacker and target.player and target.player > 0 and target.player ~= playerId then
                impact.factionAttackCount = impact.factionAttackCount + 1
                local damage = 0
                if ai and ai.calculateDamage then
                    local ok, value = pcall(ai.calculateDamage, ai, attacker, target)
                    if ok then
                        damage = num(value, 0)
                    end
                end
                if damage > 0 then
                    impact.damagingFactionAttackCount = impact.damagingFactionAttackCount + 1
                    impact.damage = impact.damage + damage
                    if tostring(target.name or "") == "Commandant" then
                        impact.commandantDamage = impact.commandantDamage + damage
                    end
                    if damage >= num(target.currentHp or target.startingHp, 0) then
                        impact.killCount = impact.killCount + 1
                    end
                end
            end
        end
    end
    return impact
end

local function earlyAttackHasHardTacticalProof(candidate, attackImpact)
    local combatClass = tostring(candidate and candidate.combatClass or "")
    if combatClass == "commandant_kill"
        or combatClass == "forced_win_setup"
        or combatClass == "immediate_defense_attack"
        or combatClass == "safe_unit_kill"
        or combatClass == "safe_commandant_pressure"
        or combatClass == "official_draw_reset_attack" then
        return true
    end
    return num(attackImpact and attackImpact.killCount, 0) > 0
        or num(attackImpact and attackImpact.commandantDamage, 0) > 0
end

local function pressureLaneCount(ai, state, playerId, plan)
    local axis = plan and plan.laneAxis or "col"
    local size = gridSize(state)
    local lanes = {}
    for _, unit in ipairs(getUnitsForPlayer(ai, state, playerId)) do
        local lane = laneNameForCell(axis, unit, size)
        if manhattan(unit, state.commandHubs and state.commandHubs[getOpponent(ai, playerId)]) <= 6 then
            lanes[lane] = true
        end
    end
    local count = 0
    for _ in pairs(lanes) do
        count = count + 1
    end
    return count
end

local function nearestFriendlySupport(ai, state, playerId, unit, excludeSelf)
    local best = 99
    for _, ally in ipairs(getUnitsForPlayer(ai, state, playerId)) do
        if not excludeSelf or ally ~= unit then
            local d = manhattan(ally, unit)
            if d < best then
                best = d
            end
        end
    end
    return best
end

local function unitAttackRange(ai, unit)
    local range = unit and unit.atkRange
    if range == nil and ai and ai.unitsInfo and ai.unitsInfo.getUnitAttackRange then
        local ok, value = pcall(ai.unitsInfo.getUnitAttackRange, ai.unitsInfo, unit, "EARLY_PLAN_ATTACK_RANGE")
        if ok then
            range = value
        end
    end
    return num(range, 1)
end

local function attackDamage(ai, attacker, target)
    if not (attacker and target) then
        return 0
    end
    if ai and ai.calculateDamage then
        local ok, value = pcall(ai.calculateDamage, ai, attacker, target)
        if ok then
            return num(value, 0)
        end
    end
    if ai and ai.unitsInfo and ai.unitsInfo.calculateAttackDamage then
        local ok, value = pcall(ai.unitsInfo.calculateAttackDamage, ai.unitsInfo, attacker, target)
        if ok then
            return num(value, 0)
        end
    end
    return num(attacker.atkDamage, 1)
end

local function canAttackCellFrom(ai, state, unit, fromCell, targetCell)
    if not (unit and fromCell and targetCell) then
        return false
    end
    local distance = manhattan(fromCell, targetCell)
    local range = unitAttackRange(ai, unit)
    if distance > range then
        return false
    end
    if fromCell.row ~= targetCell.row and fromCell.col ~= targetCell.col then
        return false
    end

    local unitName = tostring(unit.name or "")
    if unitName == "Cloudstriker" then
        if distance <= 1 then
            return false
        end
        if ai and ai.hasLineOfSight then
            local ok, hasLine = pcall(ai.hasLineOfSight, ai, state, fromCell, targetCell)
            return ok and hasLine == true
        end
        return true
    end
    if unitName == "Artillery" then
        return distance > 1
    end
    return distance <= range
end

local function friendlyControlsCell(ai, state, playerId, cell, excludeUnit)
    for _, ally in ipairs(getUnitsForPlayer(ai, state, playerId)) do
        if ally ~= excludeUnit and canAttackCellFrom(ai, state, ally, ally, cell) then
            return true
        end
    end
    return false
end

local function moveAttackExposure(ai, state, playerId, enemyPlayer, movedUnit)
    local result = {
        threatened = false,
        covered = false,
        lethal = false,
        damage = 0,
        tradeNet = 0,
        replyKind = nil,
        replyEta = nil,
        reason = nil
    }
    if not (state and movedUnit) then
        return result
    end

    if punishMap and punishMap.analyzeCell then
        local analysis = punishMap.analyzeCell(state, ai, {
            aiPlayer = playerId,
            enemyPlayer = enemyPlayer,
            phase = {name = "early"}
        }, movedUnit, movedUnit)
        local reply = analysis and analysis.enemyBestReply or nil
        result.threatened = reply ~= nil
        result.covered = analysis and analysis.covered == true or false
        result.lethal = reply and reply.lethal == true or false
        result.counterLethal = analysis and analysis.counterPunish and analysis.counterPunish.lethal == true or false
        result.damage = num(reply and reply.damage, 0)
        result.replyKind = reply and reply.kind or nil
        result.replyEta = reply and num(reply.eta, 0) or nil
        result.exposureRatio = num(analysis and analysis.exposure, 0)
        result.tradeNet = num(analysis and analysis.tradeNet, 0)
        result.reason = analysis and analysis.reasons and analysis.reasons[1] or nil
        return result
    end

    return result
end

local function unitAfterAction(ai, afterState, action, playerId)
    if not action then
        return nil
    end
    if action.type == "move" or action.type == "supply_deploy" then
        return getUnitAt(ai, afterState, action.target and action.target.row, action.target and action.target.col)
    end
    if action.unit then
        return getUnitAt(ai, afterState, action.unit.row, action.unit.col)
    end
    local _ = playerId
    return nil
end

local function candidateAttacksFromCell(candidate, row, col)
    if not (candidate and row and col) then
        return false
    end
    for _, action in ipairs(candidate.actions or {}) do
        if action
            and action.type == "attack"
            and action.unit
            and num(action.unit.row, -999) == row
            and num(action.unit.col, -999) == col then
            return true
        end
    end
    return false
end

local function hasNonRetreatMoveAlternative(ai, state, playerId, ownHub, enemyHub, unit)
    if not (ai and ai.collectLegalActions and state and unit and ownHub and enemyHub) then
        return true
    end

    local sawMove = false
    for _, entry in ipairs(ai:collectLegalActions(state, {
        aiPlayer = playerId,
        includeMove = true,
        includeAttack = false,
        includeRepair = false,
        includeDeploy = false
    }) or {}) do
        local action = entry and (entry.action or entry)
        if action
            and action.type == "move"
            and action.unit
            and num(action.unit.row, -999) == num(unit.row, -998)
            and num(action.unit.col, -999) == num(unit.col, -998)
            and action.target then
            sawMove = true
            local progress = forwardProgress(ownHub, enemyHub, unit, action.target)
            if progress >= 0 then
                return true
            end
        end
    end

    return not sawMove
end

function M.scoreCandidateBias(ai, beforeState, afterOurTurn, candidate, ctx)
    local plan = ctx and ctx.earlyPlan
    local result = {
        active = plan and plan.active == true or false,
        value = 0,
        position = 0,
        efficiency = 0,
        deploy = 0,
        support = 0,
        spread = 0,
        projectilePenalty = 0,
        moveAttackTrap = false,
        responseTrap = false,
        reasons = {}
    }
    if not (plan and plan.active and candidate and afterOurTurn and ctx and ctx.aiPlayer) then
        return result
    end

    local maxValue = cfgValue(ctx, "EARLY_PLAN_CANDIDATE_BONUS_MAX", 650)
    local playerId = ctx.aiPlayer
    local enemyPlayer = ctx.enemyPlayer or getOpponent(ai, playerId)
    local ownHub = beforeState and beforeState.commandHubs and beforeState.commandHubs[playerId]
    local enemyHub = beforeState and beforeState.commandHubs and beforeState.commandHubs[enemyPlayer]
    local attackImpact = factionAttackImpact(ai, beforeState, candidate, playerId)
    local hasDamagingFactionAttack = attackImpact.damagingFactionAttackCount > 0
    local hardTacticalAttack = earlyAttackHasHardTacticalProof(candidate, attackImpact)

    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "supply_deploy" then
            local deployScore = M.scoreDeployAction(ai, beforeState, action, playerId, ctx, plan)
            result.deploy = result.deploy + (deployScore.value * 0.55)
            if deployScore.value > 0 then
                result.reasons[#result.reasons + 1] = "early_deploy_matches_plan"
            end
        elseif action and action.type == "attack" and action.unit and action.target then
            local attacker = getUnitAt(ai, afterOurTurn, action.unit.row, action.unit.col)
                or getUnitAt(ai, beforeState, action.unit.row, action.unit.col)
            local target = getUnitAt(ai, beforeState, action.target.row, action.target.col)
            if attacker then
                local hp = num(attacker.currentHp or attacker.startingHp, 0)
                local startingHp = math.max(1, num(attacker.startingHp, hp))
                local woundedRatioMax = cfgValue(ctx, "EARLY_WOUNDED_RETALIATION_HP_RATIO_MAX", 0.5)
                local wounded = hp > 0 and (hp / startingHp) <= woundedRatioMax
                local targetIsEnemyFaction = target
                    and num(target.player, 0) > 0
                    and num(target.player, 0) ~= playerId
                local damage = target and attackDamage(ai, attacker, target) or 0
                local targetHp = num(target and (target.currentHp or target.startingHp), 0)
                local killsTarget = targetIsEnemyFaction and targetHp > 0 and damage >= targetHp
                if wounded and not hardTacticalAttack and not killsTarget then
                    result.efficiency = result.efficiency
                        - cfgValue(ctx, "EARLY_WOUNDED_LOW_VALUE_ACTION_PENALTY", 950)
                    result.reasons[#result.reasons + 1] = "early_wounded_action_needs_retreat_or_tactic"
                end
            end
	        elseif action and action.type == "move" and action.target then
	            local beforeUnit = getUnitAt(ai, beforeState, action.unit and action.unit.row, action.unit and action.unit.col)
	            local afterUnit = unitAfterAction(ai, afterOurTurn, action, playerId)
	            if beforeUnit and afterUnit then
	                local beforeHp = num(beforeUnit.currentHp or beforeUnit.startingHp, 0)
	                local beforeStartingHp = math.max(1, num(beforeUnit.startingHp, beforeHp))
	                local woundedRatioMax = cfgValue(ctx, "EARLY_WOUNDED_RETALIATION_HP_RATIO_MAX", 0.5)
	                local woundedMover = beforeHp > 0 and (beforeHp / beforeStartingHp) <= woundedRatioMax
	                local beforeExposure = nil
		                local afterExposure = nil
		                local woundedThreatReducingMove = false
		                local woundedTempoTaxMove = false
		                if woundedMover and not hardTacticalAttack then
		                    beforeExposure = moveAttackExposure(ai, beforeState, playerId, enemyPlayer, beforeUnit)
		                    afterExposure = moveAttackExposure(ai, afterOurTurn, playerId, enemyPlayer, afterUnit)
	                    local beforeThreatDamage = beforeExposure.lethal and beforeHp or num(beforeExposure.damage, 0)
	                    local afterThreatDamage = afterExposure.lethal and beforeHp or num(afterExposure.damage, 0)
	                    local damageReduction = math.max(0, beforeThreatDamage - afterThreatDamage)
	                    local leavesThreat = beforeExposure.threatened == true and afterExposure.threatened ~= true
	                    local leavesLethal = beforeExposure.lethal == true and afterExposure.lethal ~= true
	                    local reducesNonLethal = beforeExposure.threatened == true
	                        and afterExposure.lethal ~= true
	                        and damageReduction > 0
		                    local createsChasePunish = beforeExposure.threatened == true
		                        and beforeExposure.covered ~= true
		                        and afterExposure.covered == true
		                        and (
		                            afterExposure.counterLethal == true
		                            or num(afterExposure.tradeNet, -9999) >= num(beforeExposure.tradeNet, -9999)
		                        )
		                    local taxesEnemyAction = beforeExposure.threatened == true
		                        and beforeExposure.lethal == true
		                        and beforeExposure.replyKind == "direct_attack"
		                        and afterExposure.threatened == true
		                        and afterExposure.replyKind ~= "direct_attack"
		                        and num(afterExposure.replyEta, 0) > num(beforeExposure.replyEta, 0)
		                        and not candidateAttacksFromCell(candidate, action.target.row, action.target.col)
		                    if leavesThreat or leavesLethal or reducesNonLethal or createsChasePunish then
		                        woundedThreatReducingMove = true
		                        local chaseTrapBonus = createsChasePunish
		                            and cfgValue(ctx, "EARLY_WOUNDED_CHASE_TRAP_BONUS", 650)
	                            or 0
	                        result.efficiency = result.efficiency
	                            + cfgValue(ctx, "EARLY_WOUNDED_RETREAT_BONUS", 900)
	                            + (damageReduction * cfgValue(ctx, "EARLY_WOUNDED_RETREAT_DAMAGE_REDUCTION_WEIGHT", 220))
	                            + chaseTrapBonus
		                        result.reasons[#result.reasons + 1] = createsChasePunish
		                            and "early_wounded_reposition_creates_chase_punish"
		                            or "early_wounded_reposition_reduces_threat"
		                    elseif taxesEnemyAction then
		                        woundedTempoTaxMove = true
		                        woundedThreatReducingMove = true
		                        local etaGain = math.max(0, num(afterExposure.replyEta, 0) - num(beforeExposure.replyEta, 0))
		                        result.efficiency = result.efficiency
		                            + cfgValue(ctx, "EARLY_WOUNDED_ACTION_TAX_BONUS", 520)
		                            + (etaGain * cfgValue(ctx, "EARLY_WOUNDED_ACTION_TAX_ETA_WEIGHT", 180))
		                        result.reasons[#result.reasons + 1] = "early_wounded_reposition_taxes_enemy_action"
		                    end
		                end

	                local supportDistance = cellListMinDistance(plan.supportCells, action.target.row, action.target.col)
	                if supportDistance <= 1 then
	                    result.support = result.support + 170
	                    result.reasons[#result.reasons + 1] = "early_move_supports_vanguard"
                elseif supportDistance == 2 then
                    result.support = result.support + 90
                    result.reasons[#result.reasons + 1] = "early_move_near_support"
                end

                local denyDistance = cellListMinDistance(plan.denyCells, action.target.row, action.target.col)
                if denyDistance <= 1 then
                    result.position = result.position + 110
                    result.reasons[#result.reasons + 1] = "early_move_creates_second_pressure"
                end

                local progress = forwardProgress(ownHub, enemyHub, beforeUnit, afterUnit)
                if progress > 0 then
                    result.position = result.position + math.min(progress * 70, 180)
                elseif progress < 0 and not hardTacticalAttack and not woundedThreatReducingMove then
                    local forcedRetreatOnlyMove = plan.role == "response"
                        and ctx
                        and ctx.cfg
                        and ctx.cfg.EARLY_RESPONSE_FORCED_RETREAT_PROOF_ENABLED == true
                        and not hasNonRetreatMoveAlternative(ai, beforeState, playerId, ownHub, enemyHub, beforeUnit)
                    if forcedRetreatOnlyMove then
                        result.reasons[#result.reasons + 1] = "early_response_forced_retreat_only_legal_moves"
                    else
                        local retreatPenalty = math.min(
                            math.abs(progress) * cfgValue(ctx, "EARLY_UNFORCED_RETREAT_PROGRESS_PENALTY", 260),
                            cfgValue(ctx, "EARLY_UNFORCED_RETREAT_MAX_PENALTY", 780)
                        )
                        result.efficiency = result.efficiency - retreatPenalty
                        result.reasons[#result.reasons + 1] = "early_unforced_retreat"
                    end
                end

                local supportRadius = cfgValue(ctx, "EARLY_PLAN_SUPPORT_RADIUS", 2)
                local support = nearestFriendlySupport(ai, afterOurTurn, playerId, afterUnit, true)
                local closeToEnemyHub = manhattan(afterUnit, enemyHub) <= cfgValue(ctx, "EARLY_PLAN_PROJECTILE_DISTANCE", 4)
                local isolated = support > supportRadius
                if closeToEnemyHub and isolated and not hardTacticalAttack then
                    result.projectilePenalty = result.projectilePenalty
                        - cfgValue(ctx, "EARLY_PLAN_PROJECTILE_PENALTY", 700)
                    result.reasons[#result.reasons + 1] = "early_unsupported_projectile_penalty"
                end

	                if not hardTacticalAttack then
	                    local exposure = afterExposure or moveAttackExposure(ai, afterOurTurn, playerId, enemyPlayer, afterUnit)
	                    if exposure.threatened
	                        and not exposure.covered
	                        and not woundedTempoTaxMove
	                        and (plan.role == "response" or exposure.lethal) then
                        local responseTrap = plan.role == "response"
                        local penalty = responseTrap
                            and cfgValue(ctx, "EARLY_RESPONSE_MOVE_ATTACK_TRAP_PENALTY", 820)
                            or cfgValue(ctx, "EARLY_MOVE_ATTACK_TRAP_PENALTY", 1600)
                        if exposure.lethal then
                            penalty = penalty + (
                                responseTrap
                                    and cfgValue(ctx, "EARLY_RESPONSE_MOVE_ATTACK_LETHAL_EXTRA_PENALTY", 260)
                                    or cfgValue(ctx, "EARLY_MOVE_ATTACK_TRAP_LETHAL_EXTRA_PENALTY", 700)
                            )
                        end
                        result.projectilePenalty = result.projectilePenalty - penalty
                        if responseTrap then
                            result.responseTrap = true
                            result.reasons[#result.reasons + 1] = "early_response_move_attack_trap"
                        else
                            result.moveAttackTrap = true
                            result.reasons[#result.reasons + 1] = "early_move_attack_trap"
                        end
	                    elseif exposure.threatened and exposure.covered then
	                        if woundedThreatReducingMove then
	                            result.position = result.position + cfgValue(ctx, "EARLY_PUNISH_MAP_MOVE_COVERED_BONUS", 120)
	                            result.reasons[#result.reasons + 1] = "early_wounded_reposition_is_covered"
	                        else
	                        local minTradeNet = cfgValue(ctx, "EARLY_COVERED_EXPOSURE_MIN_TRADE_NET", 0)
	                        if exposure.counterLethal ~= true then
	                            minTradeNet = math.max(
                                minTradeNet,
                                cfgValue(ctx, "EARLY_COVERED_EXPOSURE_NONLETHAL_MIN_TRADE_NET", minTradeNet)
                            )
                        end
                        local maxDamageRatio = cfgValue(ctx, "EARLY_COVERED_EXPOSURE_MAX_DAMAGE_RATIO", 0.34)
                        local firstHitTooLarge = num(exposure.exposureRatio, 0) > maxDamageRatio
                        if exposure.tradeNet < minTradeNet or firstHitTooLarge then
                            local basePenalty = plan.role == "response"
                                and cfgValue(ctx, "EARLY_RESPONSE_COVERED_BAD_TRADE_PENALTY", 620)
                                or cfgValue(ctx, "EARLY_COVERED_BAD_TRADE_PENALTY", 520)
                            local tradeGap = math.max(0, minTradeNet - exposure.tradeNet)
                            local damageGap = firstHitTooLarge
                                and (num(exposure.exposureRatio, 0) - maxDamageRatio)
                                or 0
                            local penalty = basePenalty
                                + (tradeGap * cfgValue(ctx, "EARLY_COVERED_BAD_TRADE_WEIGHT", 90))
                                + (damageGap * cfgValue(ctx, "EARLY_COVERED_BAD_TRADE_WEIGHT", 90))
                            result.projectilePenalty = result.projectilePenalty - penalty
                            result.weakCoveredExposure = true
                            result.reasons[#result.reasons + 1] = "early_covered_bad_trade_exposure"
                            if plan.role == "response" then
                                result.reasons[#result.reasons + 1] = "early_response_bad_covered_interdiction"
                            end
	                        elseif plan.role == "response" then
	                            result.position = result.position
	                                + cfgValue(ctx, "EARLY_RESPONSE_COVERED_INTERDICTION_BONUS", 150)
	                            result.reasons[#result.reasons + 1] = "early_response_covered_interdiction"
	                        end
	                        end
	                    end
	                end

                if action.target and not hardTacticalAttack and not result.responseTrap and not result.moveAttackTrap then
                    applyStrategicQuestionBias(
                        result,
                        ai,
                        beforeState,
                        ctx,
                        plan,
                        action.target.row,
                        action.target.col,
                        "move",
                        {targetField = "position"}
                    )
                end

                if punishMap and punishMap.analyzeCell and not hardTacticalAttack then
                    local analysis = punishMap.analyzeCell(afterOurTurn, ai, ctx, afterUnit, afterUnit)
                    if analysis and analysis.enemyBestReply then
                        if analysis.covered == true then
                            result.position = result.position
                                + cfgValue(ctx, "EARLY_PUNISH_MAP_MOVE_COVERED_BONUS", 120)
                            result.reasons[#result.reasons + 1] = "early_punish_map_move_covered"
                        else
                            local penalty = cfgValue(ctx, "EARLY_PUNISH_MAP_MOVE_UNCOVERED_PENALTY", 520)
                            if analysis.enemyBestReply.lethal then
                                penalty = penalty
                                    + cfgValue(ctx, "EARLY_PUNISH_MAP_MOVE_LETHAL_EXTRA_PENALTY", 260)
                            end
                            result.projectilePenalty = result.projectilePenalty - penalty
                            result.reasons[#result.reasons + 1] = "early_punish_map_move_uncovered"
                        end
                    end
                end

                if isSlowSiegeUnit(tostring(beforeUnit.name or ""), ctx) then
                    if progress > 0 then
                        result.position = result.position
                            - math.min(progress * cfgValue(ctx, "EARLY_SLOW_SIEGE_MOVE_VANGUARD_PENALTY", 180), 360)
                        result.reasons[#result.reasons + 1] = "early_slow_siege_move_not_vanguard"
                    end
                    if denyDistance <= 1 then
                        result.position = result.position - cfgValue(ctx, "EARLY_SLOW_SIEGE_DANGER_ZONE_PENALTY", 260)
                        result.reasons[#result.reasons + 1] = "early_slow_siege_move_not_deny_piece"
                    end
                    if support > supportRadius then
                        result.efficiency = result.efficiency
                            - cfgValue(ctx, "EARLY_SLOW_SIEGE_UNSUPPORTED_PENALTY", 180)
                        result.reasons[#result.reasons + 1] = "early_slow_siege_move_needs_screen"
                    end
                end
            end
        end
    end

    local beforeLanes = pressureLaneCount(ai, beforeState, playerId, plan)
    local afterLanes = pressureLaneCount(ai, afterOurTurn, playerId, plan)
    if afterLanes > beforeLanes then
        result.spread = result.spread + ((afterLanes - beforeLanes) * 130)
        result.reasons[#result.reasons + 1] = "early_widens_pressure_lanes"
    end

    if hardTacticalAttack then
        result.efficiency = result.efficiency + math.min(attackImpact.damage * 24, 160)
        result.reasons[#result.reasons + 1] = "early_tactics_remain_allowed"
    elseif hasDamagingFactionAttack then
        result.reasons[#result.reasons + 1] = "early_generic_attack_deferred_to_hard_tactics"
    end

    result.value = clamp(
        result.position + result.efficiency + result.deploy + result.support + result.spread + result.projectilePenalty,
        -maxValue,
        maxValue
    )
    if (result.responseTrap == true or result.moveAttackTrap == true) and not hasDamagingFactionAttack then
        result.value = -maxValue * 4
    end
    return result
end

function M.applyRoleDemandBias(demand, plan, ctx)
    if not (demand and plan and plan.active) then
        return demand
    end
    local scale = cfgValue(ctx, "EARLY_PLAN_ROLE_DEMAND_SCALE", 0.30)
    for role, value in pairs(plan.roleDemand or {}) do
        demand[role] = math.max(num(demand[role], 0), num(value, 0) * scale)
    end
    demand.reasons = demand.reasons or {}
    demand.reasons[#demand.reasons + 1] = "early_plan_role_bias"
    return demand
end

function M.applyDemandBias(demand, plan, ctx)
    return M.applyRoleDemandBias(demand, plan, ctx)
end

function M.scoreDeploy(ai, state, deployAction, playerId, ctx, demand)
    local _ = demand
    local contracts = ctx and ctx.activeContracts or {}
    if contracts.defenseActive == true then
        return 0, {
            value = 0,
            reasons = {"suppressed_by_defense_contract"}
        }
    end
    local details = M.scoreDeployAction(ai, state, deployAction, playerId, ctx, ctx and ctx.earlyPlan or nil)
    return num(details and details.value, 0), details
end

function M.selectInitialDeployment(ai, state, ctx, supply, availableCells, hubPos)
    if not (ai and state and supply and availableCells and hubPos) then
        return nil
    end
    if #supply == 0 or #availableCells == 0 then
        return nil
    end

    local playerId = ctx and ctx.aiPlayer or (ai.getFactionId and ai:getFactionId()) or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or getOpponent(ai, playerId)
    local localCtx = ctx or {}
    localCtx.aiPlayer = localCtx.aiPlayer or playerId
    localCtx.enemyPlayer = localCtx.enemyPlayer or enemyPlayer
    localCtx.cfg = localCtx.cfg or (ai.getTournamentConfig and ai:getTournamentConfig()) or {}
    localCtx.selfAI = localCtx.selfAI or ai
    localCtx.supply = localCtx.supply or {
        own = {count = #supply},
        enemy = {count = #(state.supply and state.supply[enemyPlayer] or {})}
    }
    if num(localCtx.supply.enemy and localCtx.supply.enemy.count, 0) <= 0 then
        localCtx.supply.enemy.count = 1
    end

    state.supply = state.supply or {}
    state.supply[playerId] = state.supply[playerId] or supply
    state.commandHubs = state.commandHubs or {}
    state.commandHubs[playerId] = state.commandHubs[playerId] or {
        row = hubPos.row,
        col = hubPos.col
    }

    localCtx.phase = localCtx.phase or M.detectPhase(ai, state, localCtx)
    localCtx.earlyPlan = localCtx.earlyPlan or M.build(ai, state, localCtx)
    if not (localCtx.earlyPlan and localCtx.earlyPlan.active == true) then
        return nil
    end

    local best = nil
    for unitIndex, unit in ipairs(supply) do
        if unit and unit.name then
            for cellIndex, cell in ipairs(availableCells) do
                if cell and cell.row and cell.col then
                    local action = {
                        type = "supply_deploy",
                        unitIndex = unitIndex,
                        unitName = unit.name,
                        target = {row = cell.row, col = cell.col},
                        hub = {row = hubPos.row, col = hubPos.col}
                    }
                    local details = M.scoreDeployAction(ai, state, action, playerId, localCtx, localCtx.earlyPlan)
                    local score = num(details and details.value, 0)
                    local vector = (localCtx.cfg.SUPPLY_ROLE_VECTOR and localCtx.cfg.SUPPLY_ROLE_VECTOR[unit.name]) or {}
                    local attackRole = num(vector.antiGround, 0)
                        + num(vector.antiFlying, 0)
                        + num(vector.commandantPressure, 0)
                    local slowSiege = isSlowSiegeUnit(unit.name, localCtx)
                    local setupViability =
                        (num(vector.antiGround, 0) * cfgValue(localCtx, "EARLY_SETUP_DAMAGE_ROLE_WEIGHT", 260))
                        + (num(vector.commandantPressure, 0) * cfgValue(localCtx, "EARLY_SETUP_PRESSURE_ROLE_WEIGHT", 220))
                        + (num(vector.mobility, 0) * cfgValue(localCtx, "EARLY_SETUP_MOBILITY_ROLE_WEIGHT", 120))
                        + (num(vector.siege, 0) * (
                            slowSiege
                                and cfgValue(localCtx, "EARLY_SETUP_SLOW_SIEGE_SIEGE_WEIGHT", 20)
                                or cfgValue(localCtx, "EARLY_SETUP_SIEGE_ROLE_WEIGHT", 120)
                        ))
                    if slowSiege then
                        score = score - cfgValue(localCtx, "EARLY_SETUP_SLOW_SIEGE_OPENING_PENALTY", 420)
                        details.reasons[#details.reasons + 1] = "early_setup_slow_siege_delayed_role"
                    end
                    if (attackRole > 0.7 or num(vector.siege, 0) > 0.5) and not slowSiege then
                        score = score + setupViability
                        details.reasons[#details.reasons + 1] = "early_setup_vanguard_viability"
                    end
                    if num(vector.blocker, 0) >= 0.8 and attackRole < 0.45 and num(vector.siege, 0) < 0.25 then
                        score = score - cfgValue(localCtx, "EARLY_SETUP_PURE_BLOCKER_PENALTY", 360)
                        details.reasons[#details.reasons + 1] = "early_setup_pure_blocker_not_vanguard"
                    end
                    if unit.name == "Healer" and num(details and details.roleFit, 0) <= 0 then
                        score = score - cfgValue(localCtx, "EARLY_SETUP_HEALER_FILLER_PENALTY", 180)
                    end
                    local hubDistance = manhattan(cell, hubPos)
                    local candidate = {
                        unitIndex = unitIndex,
                        unitName = unit.name,
                        cellIndex = cellIndex,
                        cell = {row = cell.row, col = cell.col},
                        action = action,
                        score = score,
                        details = details,
                        plan = localCtx.earlyPlan,
                        phase = localCtx.phase,
                        hubDistance = hubDistance
                    }
                    if not best
                        or candidate.score > best.score
                        or (candidate.score == best.score and candidate.hubDistance < best.hubDistance)
                        or (
                            candidate.score == best.score
                            and candidate.hubDistance == best.hubDistance
                            and candidate.unitIndex < best.unitIndex
                        ) then
                        best = candidate
                    end
                end
            end
        end
    end

    local minScore = cfgValue(localCtx, "EARLY_SETUP_MIN_SCORE", 20)
    if best and best.score >= minScore then
        return best
    end

    return nil
end

function M.scoreCandidate(ai, beforeState, afterOurTurn, candidate, ctx, opts)
    local _ = opts
    local contracts = ctx and ctx.activeContracts or {}
    if contracts.defenseActive == true then
        return {
            active = false,
            value = 0,
            reasons = {"suppressed_by_defense_contract"}
        }
    end
    return M.scoreCandidateBias(ai, beforeState, afterOurTurn, candidate, ctx)
end

return M
