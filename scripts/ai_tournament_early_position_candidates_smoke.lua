package.path = package.path .. ";./?.lua"

local results = {}

local function runTest(name, fn)
    local startedAt = os.clock()
    local ok, err = xpcall(fn, debug.traceback)
    results[#results + 1] = {
        name = name,
        ok = ok,
        err = err,
        ms = (os.clock() - startedAt) * 1000
    }
end

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error((message or "assertEquals failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    for key, child in pairs(value) do
        out[deepCopy(key, seen)] = deepCopy(child, seen)
    end
    return out
end

local function unit(name, player, row, col)
    return {
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = 4,
        startingHp = 4,
        hasActed = false,
        hasMoved = false,
        actionsUsed = 0
    }
end

local function stateWith(units, supply)
    return {
        currentPlayer = 1,
        currentTurn = 2,
        turnNumber = 2,
        gridSize = 8,
        units = units or {},
        neutralBuildings = {},
        commandHubs = {
            [1] = unit("Commandant", 1, 1, 1),
            [2] = unit("Commandant", 2, 8, 8)
        },
        supply = {
            [1] = supply or {},
            [2] = {}
        }
    }
end

local function findUnitAt(state, row, col)
    for _, item in ipairs(state.units or {}) do
        if item.row == row and item.col == col then
            return item
        end
    end
    return nil
end

local function simulate(state, sequence, playerId)
    local after = deepCopy(state)
    for _, action in ipairs(sequence or {}) do
        if action.type == "supply_deploy" then
            local supply = after.supply and after.supply[playerId] or {}
            local deployed = table.remove(supply, action.unitIndex)
            if deployed and action.target then
                deployed.row = action.target.row
                deployed.col = action.target.col
                deployed.player = playerId
                deployed.hasActed = true
                deployed.actionsUsed = 1
                after.units[#after.units + 1] = deployed
            end
        elseif action.type == "move" and action.unit and action.target then
            local moved = findUnitAt(after, action.unit.row, action.unit.col)
            if moved then
                moved.row = action.target.row
                moved.col = action.target.col
                moved.hasMoved = true
                moved.actionsUsed = (moved.actionsUsed or 0) + 1
            end
        end
    end
    return after
end

local function signature(actions)
    local parts = {}
    for _, action in ipairs(actions or {}) do
        if action.type == "supply_deploy" then
            parts[#parts + 1] = string.format("deploy:%s>%d,%d", action.unitName, action.target.row, action.target.col)
        elseif action.type == "move" then
            parts[#parts + 1] = string.format(
                "move:%d,%d>%d,%d",
                action.unit.row,
                action.unit.col,
                action.target.row,
                action.target.col
            )
        else
            parts[#parts + 1] = tostring(action.type)
        end
    end
    return table.concat(parts, "|")
end

local function baseCtx(opts)
    opts = opts or {}
    local ctx = {
        aiPlayer = 1,
        enemyPlayer = 2,
        cfg = {
            PIPELINE_V2_REAL_COVER_ENABLED = opts.realCover,
            PIPELINE_V2_DEPLOY_FIRST_EARLY_SECOND_ENABLED = opts.earlySecond,
            PIPELINE_V2_DEPLOY_FIRST_EARLY_SECOND_LOCKED_COVER_ENABLED = opts.lockedCoverSecond,
            PIPELINE_V2_STABLE_COVER_ENABLED = opts.stableCover,
            PIPELINE_V2_COVER_REPOSITION_ENABLED = opts.coverReposition,
            PIPELINE_V2_UNCOVERED_ADVANCE_ENABLED = opts.uncoveredAdvance,
            PIPELINE_V2_UNCOVERED_ADVANCE_MIN_GAIN = opts.uncoveredAdvanceMinGain,
            PIPELINE_V2_EARLY_SAFE_CELL_POLICY_ENABLED = opts.safeCellPolicy,
            PIPELINE_V2_EARLY_HOLD_NONLETHAL_OCCUPIED_THREAT = opts.holdNonLethalOccupiedThreat,
            PIPELINE_V2_EARLY_HOLD_THREAT_COVER_BONUS = opts.holdThreatCoverBonus,
            PIPELINE_V2_EARLY_RETREAT_ENABLED = opts.earlyRetreat,
            PIPELINE_V2_EARLY_RETREAT_SCORE_BONUS = opts.retreatScoreBonus,
            PIPELINE_V2_EARLY_STRATEGIC_MIN_VALUE = opts.strategicMinValue,
            PIPELINE_V2_EARLY_SEQUENCE_ENABLED = opts.earlySequence,
            PIPELINE_V2_EARLY_FORMED_PAIR_RELEASE_ENABLED = opts.formedPairRelease,
            PIPELINE_V2_DESTINATION_EXPOSURE_GUARD_ENABLED = opts.destinationExposureGuard,
            PIPELINE_V2_DESTINATION_EXPOSURE_SCORING_ENABLED = opts.destinationExposureScoring,
            PIPELINE_V2_EARLY_MOVE_RISK_ORDERING_ENABLED = opts.earlyMoveRiskOrdering,
            PIPELINE_V2_EARLY_SUICIDAL_MOVE_PENALTY = opts.earlySuicidalMovePenalty,
            PIPELINE_V2_EARLY_FORCED_MOVE_VALUE_ENABLED = opts.earlyForcedMoveValue,
            PIPELINE_V2_EARLY_FORCED_MOVE_OWNED_CELL_CHURN_PENALTY = opts.earlyForcedOwnedCellChurnPenalty,
            PIPELINE_V2_EARLY_LEGAL_FLOOR_ENABLED = opts.earlyLegalFloor,
            PIPELINE_V2_EARLY_LEGAL_FLOOR_CANDIDATE_CAP = opts.earlyLegalFloorCap,
            PIPELINE_V2_EARLY_LEGAL_FLOOR_PENALTY = opts.earlyLegalFloorPenalty,
            PIPELINE_V2_EARLY_DESTINATION_DAMAGE_PENALTY = opts.earlyDestinationDamagePenalty,
            PIPELINE_V2_EARLY_DESTINATION_LETHAL_PENALTY = opts.earlyDestinationLethalPenalty,
            PIPELINE_V2_EARLY_DESTINATION_DAMAGE_WEIGHT = opts.earlyDestinationDamageWeight,
            PIPELINE_V2_FULL_TURN_EXACT_SANITIZE_ENABLED = opts.fullTurnExactSanitize,
            PIPELINE_V2_FULL_TURN_FORCED_SECOND_ENABLED = opts.fullTurnForcedSecond,
            PIPELINE_V2_FULL_TURN_FORCED_DEPLOY_SECOND_ENABLED = opts.fullTurnForcedDeploySecond,
            PIPELINE_V2_FULL_TURN_FORCED_DEPLOY_SECOND_SCAN_CAP = opts.fullTurnForcedDeploySecondScanCap,
            PIPELINE_V2_FULL_TURN_TECHNICAL_SECOND_ENABLED = opts.fullTurnTechnicalSecond,
            PIPELINE_V2_FULL_TURN_TECHNICAL_SECOND_SCAN_CAP = opts.fullTurnTechnicalSecondScanCap,
            PIPELINE_V2_EARLY_GATE_ALLOW_TECHNICAL_SECOND = opts.earlyGateAllowTechnicalSecond,
            PIPELINE_V2_POSITION_PATTERN_PENALTY_ENABLED = opts.positionPatternPenalty,
            PIPELINE_V2_POSITION_PATTERN_PENALTY_CAP = opts.positionPatternPenaltyCap,
            PIPELINE_V2_STRICT_SUPPORT_COVER_ENABLED = opts.strictSupportCover,
            PIPELINE_V2_EARLY_STAGING_ENABLED = opts.earlyStaging,
            PIPELINE_V2_DEPLOY_EXTRA_MS = opts.deployExtraMs
        },
        stats = {},
        cache = {},
        turnEnumerator = {}
    }
    ctx.cache.simulate = function(_, state, sequence, playerId)
        if opts.simulateCalls then
            opts.simulateCalls.count = (opts.simulateCalls.count or 0) + 1
        end
        return simulate(state, sequence, playerId)
    end
    ctx.turnEnumerator.sequenceSignature = signature
    ctx.turnEnumerator.collectTournamentActions = function()
        return opts.moveEntries or {}
    end
    ctx.supplyPlanner = {
        getDeployActionEntries = function()
            return opts.deployEntries or {}
        end
    }
    return ctx
end

local function positionMap()
    return {
        ownedUncovered = {
            {key = "2,2", row = 2, col = 2, status = "owned_uncovered", value = 300}
        },
        ownedCovered = {},
        freeTargets = {},
        nextExpansion = {},
        freeTop = {},
        top = {}
    }
end

local function positionMapWith(sourceStatus, sourceValue, targetStatus, targetValue, targetRow, targetCol)
    local source = {key = "2,2", row = 2, col = 2, status = sourceStatus, value = sourceValue}
    local row = targetRow or 2
    local col = targetCol or 3
    local target = {key = tostring(row) .. "," .. tostring(col), row = row, col = col, status = targetStatus, value = targetValue}
    local map = {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {},
        nextExpansion = {},
        freeTop = {},
        top = {source, target}
    }
    if sourceStatus == "owned_uncovered" then
        map.ownedUncovered[1] = source
    elseif sourceStatus == "owned_covered" then
        map.ownedCovered[1] = source
    end
    if targetStatus == "free_target" then
        map.freeTargets[1] = target
        map.freeTop[1] = target
    elseif targetStatus == "next_expansion" then
        map.nextExpansion[1] = target
        map.freeTop[1] = target
    end
    return map
end

runTest("early_sequence_skips_resolved_and_targets_next_open_cell", function()
    local sequence = require("ai_tournament.early_position_sequence")
    local agenda = sequence.build({
        top = {
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 900},
            {key = "2,3", row = 2, col = 3, status = "owned_uncovered", value = 420},
            {key = "2,4", row = 2, col = 4, status = "free_target", value = 300}
        },
        ownedCovered = {
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 900}
        },
        ownedUncovered = {
            {key = "2,3", row = 2, col = 3, status = "owned_uncovered", value = 420}
        },
        freeTargets = {
            {key = "2,4", row = 2, col = 4, status = "free_target", value = 300}
        }
    }, baseCtx({strategicMinValue = 120}))

    assertEquals(sequence.describe(agenda.primary), "2,3:cover:420")
end)

runTest("early_sequence_can_be_disabled", function()
    local sequence = require("ai_tournament.early_position_sequence")
    local agenda = sequence.build({
        top = {
            {key = "2,3", row = 2, col = 3, status = "owned_uncovered", value = 420}
        },
        ownedUncovered = {
            {key = "2,3", row = 2, col = 3, status = "owned_uncovered", value = 420}
        }
    }, baseCtx({earlySequence = false}))

    assertEquals(sequence.describe(agenda.primary), "none")
end)

runTest("deploy_does_not_count_as_cover_on_entry", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local state = stateWith({unit("Crusher", 1, 2, 2)}, {{name = "Crusher", currentHp = 4, startingHp = 4}})
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Crusher",
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        deployEntries = {{action = deploy}}
    })

    local generated = candidates.generateDeployFirst(nil, state, ctx, positionMap(), {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 0, "fresh deploy should not be accepted as cover")
    assertEquals(ctx.stats.pipelineV2DeployFirstCoverMode, "deploy_not_cover")
    assertEquals(ctx.stats.pipelineV2DeployFirstRealCoverHits, 0, "deploy cover should not be checked")
end)

runTest("diagonal_deploy_is_not_real_cover", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local state = stateWith({unit("Crusher", 1, 2, 2)}, {{name = "Crusher", currentHp = 4, startingHp = 4}})
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Crusher",
        target = {row = 3, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        deployEntries = {{action = deploy}}
    })

    local generated = candidates.generateDeployFirst(nil, state, ctx, positionMap(), {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 0, "diagonal deploy should not be accepted as real cover")
    assertEquals(ctx.stats.pipelineV2DeployFirstRealCoverHits, 0, "real cover miss should be counted")
end)

runTest("deploy_first_can_disable_early_second_and_stay_pure", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local mover = unit("Crusher", 1, 4, 4)
    local state = stateWith({mover}, {{name = "Crusher", currentHp = 4, startingHp = 4}})
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Crusher",
        target = {row = 2, col = 3}
    }
    local move = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 3, col = 4}
    }
    local ctx = baseCtx({
        realCover = true,
        earlySecond = false,
        deployEntries = {{action = deploy}},
        moveEntries = {{action = move, unit = mover, cheapScore = 20}}
    })

    local generated = candidates.generateDeployFirst(nil, state, ctx, positionMapWith(
        nil,
        0,
        "free_target",
        240
    ), {
        maxCandidates = 4,
        continuationCap = 4
    })

    assertEquals(#generated, 1, "deploy-first should stay pure when early second is disabled")
    assertEquals(generated[1].signature, "deploy:Crusher>2,3")
    assertEquals(ctx.stats.pipelineV2DeployFirstContinuationMode, "pure_deploy_only")
    assertEquals(ctx.stats.pipelineV2DeployFirstContinuationCandidates, 0)
end)

runTest("deploy_first_adds_early_second_cover_target", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local cover = unit("Crusher", 1, 4, 3)
    local state = stateWith({cover}, {{name = "Crusher", currentHp = 4, startingHp = 4}})
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Crusher",
        target = {row = 2, col = 3}
    }
    local move = {
        type = "move",
        unit = {row = cover.row, col = cover.col},
        target = {row = 3, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        deployEntries = {{action = deploy}},
        moveEntries = {{action = move, unit = cover, cheapScore = 0}}
    })

    local generated = candidates.generateDeployFirst(nil, state, ctx, positionMapWith(
        nil,
        0,
        "free_target",
        240
    ), {
        maxCandidates = 4,
        continuationCap = 0,
        earlySecondScanCap = 4
    })

    local found = false
    for _, candidate in ipairs(generated) do
        if candidate.signature == "deploy:Crusher>2,3|move:4,3>3,3" then
            found = true
            assertEquals(candidate.tacticalTags.earlyPositionReason, "occupy_free_target_then_cover_target")
        end
    end
    assertTrue(found, "expected deploy-first to add an early-aware cover move")
    assertEquals(ctx.stats.pipelineV2DeployFirstContinuationMode, "early_second_action")
    assertEquals(ctx.stats.pipelineV2DeployFirstContinuationCandidates, 1)
    assertEquals(ctx.stats.pipelineV2DeployFirstEarlySecondReasonCounts.cover_target, 1)
end)

runTest("deploy_first_second_action_can_expand_when_not_covering_target", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local mover = unit("Wingstalker", 1, 5, 5)
    local state = stateWith({mover}, {{name = "Crusher", currentHp = 4, startingHp = 4}})
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Crusher",
        target = {row = 3, col = 4}
    }
    local move = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 5, col = 6}
    }
    local ctx = baseCtx({
        realCover = true,
        deployEntries = {{action = deploy}},
        moveEntries = {{action = move, unit = mover, cheapScore = 0}}
    })
    local deployTarget = {
        key = "3,4",
        row = 3,
        col = 4,
        status = "free_target",
        value = 700
    }
    local expansionTarget = {
        key = "5,6",
        row = 5,
        col = 6,
        status = "free_target",
        value = 360
    }

    local generated = candidates.generateDeployFirst(nil, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {deployTarget, expansionTarget},
        nextExpansion = {},
        freeTop = {deployTarget, expansionTarget},
        top = {deployTarget, expansionTarget}
    }, {
        maxCandidates = 4,
        continuationCap = 0,
        earlySecondScanCap = 4
    })

    local found = false
    for _, candidate in ipairs(generated) do
        if candidate.signature == "deploy:Crusher>3,4|move:5,5>5,6" then
            found = true
            assertEquals(candidate.tacticalTags.earlyPositionReason, "occupy_free_target_then_free_expand")
        end
    end
    assertTrue(found, "deploy-first should allow a safe expansion as the second action")
    assertEquals(ctx.stats.pipelineV2DeployFirstEarlySecondReasonCounts.free_expand, 1)
    assertEquals(ctx.stats.pipelineV2DeployFirstEarlySecondSkippedReasons.early_second_not_covering_target, nil)
end)

runTest("early_second_penalizes_enemy_move_attack_kill_before_selection", function()
    local secondAction = require("ai_tournament.early_position_second_action")
    local unsafeMover = unit("Crusher", 1, 4, 1)
    local safeMover = unit("Wingstalker", 1, 2, 2)
    local enemy = unit("Earthstalker", 2, 4, 5)
    enemy.move = 1
    enemy.atkRange = 1
    enemy.atkDamage = 4
    local state = stateWith({unsafeMover, safeMover, enemy}, {
        {name = "Bastion", currentHp = 6, startingHp = 6}
    })
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Bastion",
        target = {row = 3, col = 4}
    }
    local unsafeMove = {
        type = "move",
        unit = {row = unsafeMover.row, col = unsafeMover.col},
        target = {row = 4, col = 3}
    }
    local safeMove = {
        type = "move",
        unit = {row = safeMover.row, col = safeMover.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        moveEntries = {
            {action = unsafeMove, unit = unsafeMover, cheapScore = 200},
            {action = safeMove, unit = safeMover, cheapScore = 0}
        }
    })
    local deployTarget = {key = "3,4", row = 3, col = 4, status = "free_target", value = 700}
    local unsafeTarget = {key = "4,3", row = 4, col = 3, status = "free_target", value = 900}
    local safeTarget = {key = "2,3", row = 2, col = 3, status = "free_target", value = 220}
    local map = {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {deployTarget, unsafeTarget, safeTarget},
        nextExpansion = {},
        freeTop = {deployTarget, unsafeTarget, safeTarget},
        top = {deployTarget, unsafeTarget, safeTarget}
    }

    local second, stats = secondAction.select(nil, state, simulate(state, {deploy}, 1), ctx, map, deploy, {
        scanCap = 4
    })

    assertTrue(second ~= nil and second.action ~= nil, "expected an early second action")
    assertEquals(signature({second.action}), "move:2,2>2,3", "safe alternative should outrank lethal reply")
    assertEquals(stats.moveRiskLethal, 1, "lethal enemy reply should be counted")
    assertTrue(stats.moveRiskPenalized >= 1, "lethal reply should apply a score penalty")
end)

runTest("early_second_penalizes_suicidal_movement_before_selection", function()
    local secondAction = require("ai_tournament.early_position_second_action")
    local unsafeMover = unit("Crusher", 1, 4, 1)
    local safeMover = unit("Wingstalker", 1, 2, 2)
    local ai = {
        isSuicidalMovement = function(_, _, target)
            return target and target.row == 4 and target.col == 3
        end
    }
    local state = stateWith({unsafeMover, safeMover}, {
        {name = "Bastion", currentHp = 6, startingHp = 6}
    })
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Bastion",
        target = {row = 3, col = 4}
    }
    local unsafeMove = {
        type = "move",
        unit = {row = unsafeMover.row, col = unsafeMover.col},
        target = {row = 4, col = 3}
    }
    local safeMove = {
        type = "move",
        unit = {row = safeMover.row, col = safeMover.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        moveEntries = {
            {action = unsafeMove, unit = unsafeMover, cheapScore = 200},
            {action = safeMove, unit = safeMover, cheapScore = 0}
        }
    })
    local deployTarget = {key = "3,4", row = 3, col = 4, status = "free_target", value = 700}
    local unsafeTarget = {key = "4,3", row = 4, col = 3, status = "free_target", value = 900}
    local safeTarget = {key = "2,3", row = 2, col = 3, status = "free_target", value = 220}
    local map = {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {deployTarget, unsafeTarget, safeTarget},
        nextExpansion = {},
        freeTop = {deployTarget, unsafeTarget, safeTarget},
        top = {deployTarget, unsafeTarget, safeTarget}
    }

    local second, stats = secondAction.select(ai, state, simulate(state, {deploy}, 1), ctx, map, deploy, {
        scanCap = 4
    })

    assertTrue(second ~= nil and second.action ~= nil, "expected an early second action")
    assertEquals(signature({second.action}), "move:2,2>2,3", "safe alternative should outrank suicidal movement")
    assertEquals(stats.moveRiskSuicidal, 1, "suicidal movement should be counted")
    assertTrue(stats.moveRiskPenalized >= 1, "suicidal movement should apply a score penalty")
end)

runTest("early_second_move_risk_ordering_is_reversible", function()
    local secondAction = require("ai_tournament.early_position_second_action")
    local unsafeMover = unit("Crusher", 1, 4, 1)
    local safeMover = unit("Wingstalker", 1, 2, 2)
    local ai = {
        isSuicidalMovement = function(_, _, target)
            return target and target.row == 4 and target.col == 3
        end
    }
    local state = stateWith({unsafeMover, safeMover}, {
        {name = "Bastion", currentHp = 6, startingHp = 6}
    })
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Bastion",
        target = {row = 3, col = 4}
    }
    local unsafeMove = {
        type = "move",
        unit = {row = unsafeMover.row, col = unsafeMover.col},
        target = {row = 4, col = 3}
    }
    local safeMove = {
        type = "move",
        unit = {row = safeMover.row, col = safeMover.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        earlyMoveRiskOrdering = false,
        moveEntries = {
            {action = unsafeMove, unit = unsafeMover, cheapScore = 200},
            {action = safeMove, unit = safeMover, cheapScore = 0}
        }
    })
    local deployTarget = {key = "3,4", row = 3, col = 4, status = "free_target", value = 700}
    local unsafeTarget = {key = "4,3", row = 4, col = 3, status = "free_target", value = 900}
    local safeTarget = {key = "2,3", row = 2, col = 3, status = "free_target", value = 220}
    local map = {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {deployTarget, unsafeTarget, safeTarget},
        nextExpansion = {},
        freeTop = {deployTarget, unsafeTarget, safeTarget},
        top = {deployTarget, unsafeTarget, safeTarget}
    }

    local second, stats = secondAction.select(ai, state, simulate(state, {deploy}, 1), ctx, map, deploy, {
        scanCap = 4
    })

    assertTrue(second ~= nil and second.action ~= nil, "expected an early second action")
    assertEquals(signature({second.action}), "move:4,1>4,3", "disabled risk ordering should restore old score order")
    assertEquals(stats.moveRiskPenalized, 0, "disabled risk ordering should not penalize moves")
end)

runTest("early_second_forced_release_orders_by_destination_value", function()
    local secondAction = require("ai_tournament.early_position_second_action")
    local occupant = unit("Earthstalker", 1, 2, 5)
    local state = stateWith({occupant}, {
        {name = "Cloudstriker", currentHp = 4, startingHp = 4}
    })
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Cloudstriker",
        target = {row = 1, col = 6}
    }
    local badStep = {
        type = "move",
        unit = {row = occupant.row, col = occupant.col},
        target = {row = 1, col = 5}
    }
    local betterStep = {
        type = "move",
        unit = {row = occupant.row, col = occupant.col},
        target = {row = 2, col = 4}
    }
    local ctx = baseCtx({
        strategicMinValue = 120,
        moveEntries = {
            {action = badStep, unit = occupant, cheapScore = 0},
            {action = betterStep, unit = occupant, cheapScore = 0}
        }
    })
    local source = {key = "2,5", row = 2, col = 5, status = "owned_uncovered", value = 410}
    local deployTarget = {key = "1,6", row = 1, col = 6, status = "free_target", value = 500}
    local badTarget = {key = "1,5", row = 1, col = 5, status = "other", value = -80}
    local betterTarget = {key = "2,4", row = 2, col = 4, status = "other", value = 80}
    local map = {
        ownedUncovered = {source},
        ownedUncoveredAll = {source},
        ownedCovered = {},
        freeTargets = {deployTarget},
        nextExpansion = {},
        freeTop = {deployTarget},
        top = {deployTarget, source, badTarget, betterTarget}
    }

    local second, stats = secondAction.select(nil, state, simulate(state, {deploy}, 1), ctx, map, deploy, {
        scanCap = 1
    })

    assertTrue(second ~= nil and second.action ~= nil, "expected a forced release second action")
    assertEquals(signature({second.action}), "move:2,5>2,4", "forced release should still prefer movement value")
    assertEquals(stats.reasonCounts.release_occupant_then_forced_step, 1)
end)

runTest("deploy_first_second_action_prioritizes_lethal_retreat_over_free_expand", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local freeMover = unit("Crusher", 1, 2, 2)
    local wounded = unit("Earthstalker", 1, 4, 4)
    wounded.currentHp = 1
    wounded.startingHp = 3
    local state = stateWith({freeMover, wounded}, {{name = "Wingstalker", currentHp = 4, startingHp = 4}})
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Wingstalker",
        target = {row = 3, col = 4}
    }
    local freeExpand = {
        type = "move",
        unit = {row = freeMover.row, col = freeMover.col},
        target = {row = 2, col = 3}
    }
    local retreat = {
        type = "move",
        unit = {row = wounded.row, col = wounded.col},
        target = {row = 4, col = 5}
    }
    local ctx = baseCtx({
        realCover = true,
        earlyRetreat = true,
        deployEntries = {{action = deploy}},
        moveEntries = {
            {action = freeExpand, unit = freeMover, cheapScore = 100},
            {action = retreat, unit = wounded, cheapScore = 0}
        }
    })
    local deployTarget = {
        key = "3,4",
        row = 3,
        col = 4,
        status = "free_target",
        value = 700
    }
    local freeTarget = {
        key = "2,3",
        row = 2,
        col = 3,
        status = "free_target",
        value = 260
    }
    local woundedSource = {
        key = "4,4",
        row = 4,
        col = 4,
        status = "owned_uncovered",
        value = 420,
        occupiedByUs = true,
        occupantHp = 1,
        occupantEnemyBestReply = {damage = 1, expectedDamage = 1, lethal = true, kind = "attack"}
    }
    local retreatTarget = {
        key = "4,5",
        row = 4,
        col = 5,
        status = "free_target",
        value = 180
    }

    local generated = candidates.generateDeployFirst(nil, state, ctx, {
        ownedUncovered = {woundedSource},
        ownedUncoveredAll = {woundedSource},
        ownedCovered = {},
        freeTargets = {deployTarget, freeTarget, retreatTarget},
        nextExpansion = {},
        freeTop = {deployTarget, freeTarget, retreatTarget},
        top = {deployTarget, woundedSource, freeTarget, retreatTarget}
    }, {
        maxCandidates = 4,
        continuationCap = 0,
        earlySecondScanCap = 1
    })

    local found = false
    for _, candidate in ipairs(generated) do
        if candidate.signature == "deploy:Wingstalker>3,4|move:4,4>4,5" then
            found = true
            assertEquals(
                candidate.tacticalTags.earlyPositionReason,
                "occupy_free_target_then_retreat_to_strategic_cell"
            )
        end
    end
    assertTrue(found, "urgent wounded retreat should be scanned before ordinary free expansion")
    assertEquals(ctx.stats.pipelineV2DeployFirstEarlySecondReasonCounts.retreat_to_strategic_cell, 1)
end)

runTest("deploy_first_can_use_second_action_to_retreat_exposed_unit", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local exposed = unit("Crusher", 1, 2, 2)
    exposed.currentHp = 2
    local state = stateWith({exposed}, {{name = "Crusher", currentHp = 4, startingHp = 4}})
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Crusher",
        target = {row = 3, col = 4}
    }
    local retreatMove = {
        type = "move",
        unit = {row = exposed.row, col = exposed.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        earlyRetreat = true,
        retreatScoreBonus = 900,
        deployEntries = {{action = deploy}},
        moveEntries = {{action = retreatMove, unit = exposed, cheapScore = 0}}
    })
    local source = {
        key = "2,2",
        row = 2,
        col = 2,
        status = "owned_uncovered",
        value = 400,
        occupiedByUs = true,
        occupantHp = 2,
        occupantEnemyBestReply = {damage = 2, expectedDamage = 2, lethal = true, kind = "move_attack"}
    }
    local deployTarget = {
        key = "3,4",
        row = 3,
        col = 4,
        status = "free_target",
        value = 500
    }
    local retreatTarget = {
        key = "2,3",
        row = 2,
        col = 3,
        status = "free_target",
        value = 260
    }

    local generated = candidates.generateDeployFirst(nil, state, ctx, {
        ownedUncovered = {source},
        ownedUncoveredAll = {source},
        ownedCovered = {},
        freeTargets = {deployTarget, retreatTarget},
        nextExpansion = {},
        freeTop = {deployTarget, retreatTarget},
        top = {deployTarget, source, retreatTarget}
    }, {
        maxCandidates = 4,
        continuationCap = 0,
        earlySecondScanCap = 4
    })

    local found = false
    for _, candidate in ipairs(generated) do
        if candidate.signature == "deploy:Crusher>3,4|move:2,2>2,3" then
            found = true
            assertEquals(
                candidate.tacticalTags.earlyPositionReason,
                "occupy_free_target_then_retreat_to_strategic_cell"
            )
        end
    end
    assertTrue(found, "deploy-first should be able to spend the second action on retreat")
    assertEquals(ctx.stats.pipelineV2DeployFirstEarlySecondReasonCounts.retreat_to_strategic_cell, 1)
end)

runTest("deploy_first_locked_cover_can_move_only_when_preserving_resolved_cover", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local resolvedOccupant = unit("Crusher", 1, 2, 2)
    local cover = unit("Crusher", 1, 2, 5)
    cover.atkRange = 3
    local state = stateWith({resolvedOccupant, cover}, {
        {name = "Crusher", currentHp = 4, startingHp = 4}
    })
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Crusher",
        target = {row = 3, col = 4}
    }
    local move = {
        type = "move",
        unit = {row = cover.row, col = cover.col},
        target = {row = 2, col = 4}
    }
    local ctx = baseCtx({
        realCover = true,
        deployEntries = {{action = deploy}},
        moveEntries = {{action = move, unit = cover, cheapScore = 0}}
    })
    local map = {
        ownedCovered = {
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 500}
        },
        ownedUncovered = {},
        freeTargets = {
            {key = "3,4", row = 3, col = 4, status = "free_target", value = 700}
        },
        nextExpansion = {},
        freeTop = {
            {key = "3,4", row = 3, col = 4, status = "free_target", value = 700}
        },
        top = {
            {key = "3,4", row = 3, col = 4, status = "free_target", value = 700},
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 500}
        }
    }

    local generated = candidates.generateDeployFirst(nil, state, ctx, map, {
        maxCandidates = 4,
        continuationCap = 0,
        earlySecondScanCap = 4
    })

    local found = false
    for _, candidate in ipairs(generated) do
        if candidate.signature == "deploy:Crusher>3,4|move:2,5>2,4" then
            found = true
            assertEquals(
                candidate.tacticalTags.earlyPositionReason,
                "occupy_free_target_then_cover_reposition_preserves_then_cover_target"
            )
        end
    end
    assertTrue(found, "locked cover should be usable as the forced second action when coverage is preserved")
    assertEquals(
        ctx.stats.pipelineV2DeployFirstEarlySecondReasonCounts.cover_reposition_preserves_then_cover_target,
        1
    )
end)

runTest("deploy_first_releases_lowest_cover_only_as_last_resort", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local resolvedOccupant = unit("Crusher", 1, 2, 2)
    local cover = unit("Crusher", 1, 2, 5)
    cover.atkRange = 3
    local state = stateWith({resolvedOccupant, cover}, {
        {name = "Crusher", currentHp = 4, startingHp = 4}
    })
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Crusher",
        target = {row = 3, col = 4}
    }
    local move = {
        type = "move",
        unit = {row = cover.row, col = cover.col},
        target = {row = 3, col = 5}
    }
    local ctx = baseCtx({
        realCover = true,
        deployEntries = {{action = deploy}},
        moveEntries = {{action = move, unit = cover, cheapScore = 0}}
    })
    local map = {
        ownedCovered = {
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 500}
        },
        ownedUncovered = {},
        freeTargets = {
            {key = "3,4", row = 3, col = 4, status = "free_target", value = 700},
            {key = "3,5", row = 3, col = 5, status = "free_target", value = 220}
        },
        nextExpansion = {},
        freeTop = {
            {key = "3,4", row = 3, col = 4, status = "free_target", value = 700},
            {key = "3,5", row = 3, col = 5, status = "free_target", value = 220}
        },
        top = {
            {key = "3,4", row = 3, col = 4, status = "free_target", value = 700},
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 500},
            {key = "3,5", row = 3, col = 5, status = "free_target", value = 220}
        }
    }

    local generated = candidates.generateDeployFirst(nil, state, ctx, map, {
        maxCandidates = 4,
        continuationCap = 0,
        earlySecondScanCap = 4
    })

    local found = false
    for _, candidate in ipairs(generated) do
        if candidate.signature == "deploy:Crusher>3,4|move:2,5>3,5" then
            found = true
            assertEquals(
                candidate.tacticalTags.earlyPositionReason,
                "occupy_free_target_then_release_cover_then_free_expand"
            )
        end
    end
    assertTrue(found, "when no pair-forming second action exists, release the cover unit")
    assertEquals(ctx.stats.pipelineV2DeployFirstEarlySecondReasonCounts.release_cover_then_free_expand, 1)
end)

runTest("deploy_first_caps_ranked_deploy_actions_without_base_simulation", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local simulateCalls = {count = 0}
    local state = stateWith({}, {
        {name = "Crusher", currentHp = 4, startingHp = 4},
        {name = "Crusher", currentHp = 4, startingHp = 4},
        {name = "Crusher", currentHp = 4, startingHp = 4}
    })
    local map = {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {
            {key = "2,2", row = 2, col = 2, status = "free_target", value = 180},
            {key = "2,3", row = 2, col = 3, status = "free_target", value = 420},
            {key = "2,4", row = 2, col = 4, status = "free_target", value = 260}
        },
        nextExpansion = {},
        freeTop = {},
        top = {
            {key = "2,2", row = 2, col = 2, status = "free_target", value = 180},
            {key = "2,3", row = 2, col = 3, status = "free_target", value = 420},
            {key = "2,4", row = 2, col = 4, status = "free_target", value = 260}
        }
    }
    local deployEntries = {
        {action = {type = "supply_deploy", unitIndex = 1, unitName = "Crusher", target = {row = 2, col = 2}}},
        {action = {type = "supply_deploy", unitIndex = 2, unitName = "Crusher", target = {row = 2, col = 3}}},
        {action = {type = "supply_deploy", unitIndex = 3, unitName = "Crusher", target = {row = 2, col = 4}}}
    }
    local ctx = baseCtx({
        realCover = true,
        earlySecond = false,
        deployEntries = deployEntries,
        simulateCalls = simulateCalls
    })

    local generated = candidates.generateDeployFirst(nil, state, ctx, map, {
        maxCandidates = 8,
        deployActionCap = 2,
        continuationCap = 0
    })

    assertEquals(#generated, 2, "deploy-first should keep only the best capped deploy actions")
    assertEquals(ctx.stats.pipelineV2DeployFirstDeployActions, 2, "considered deploy actions should reflect the cap")
    assertEquals(ctx.stats.pipelineV2DeployFirstTotalDeployActions, 3, "total deploy actions should still be tracked")
    assertEquals(simulateCalls.count, 0, "pure base deploy candidates should not simulate post-deploy state")
    assertEquals(generated[1].signature, "deploy:Crusher>2,3", "highest value target should rank first")
    assertEquals(generated[2].signature, "deploy:Crusher>2,4", "second highest value target should rank second")
end)

runTest("deploy_first_uses_extra_budget_for_scored_deploy", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Wingstalker",
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        strategicMinValue = 120,
        deployExtraMs = 80
    })
    ctx.hardBudgetMs = 100
    ctx.elapsedMs = function()
        return 130
    end
    ctx.remainingMs = function()
        return math.max(0, ctx.hardBudgetMs - ctx.elapsedMs())
    end
    ctx.shouldStop = function()
        return ctx.elapsedMs() >= ctx.hardBudgetMs
    end
    ctx.supplyPlanner.getDeployActionEntries = function(_, _, _, activeCtx)
        if activeCtx.shouldStop and activeCtx.shouldStop() then
            return {}
        end
        return {{
            action = deploy,
            target = deploy.target,
            cheapScore = 100
        }}
    end

    local map = positionMapWith("owned_uncovered", 100, "free_target", 320, 2, 3)
    local generated = candidates.generateDeployFirst(nil, stateWith({}, {{name = "Wingstalker"}}), ctx, map, {
        maxCandidates = 4,
        deployActionCap = 4,
        earlySecondScanCap = 0
    })

    assertEquals(#generated, 1, "deploy budget should let scored deploy generation run")
    assertEquals(ctx.stats.pipelineV2DeployFirstBudgetExtraMs, 80)
    assertEquals(ctx.stats.pipelineV2DeployFirstBudgetRemainingBeforeMs, 0)
    assertEquals(ctx.stats.pipelineV2DeployFirstBudgetStartElapsedMs, 130)
    assertEquals(ctx.stats.pipelineV2DeployFirstBudgetExtendedHardBudgetMs, 210)
    assertEquals(ctx.stats.pipelineV2DeployFirstBudgetLocalWindowMs, 80)
    assertEquals(ctx.stats.pipelineV2DeployFirstBudgetUses, 1)
    assertEquals(ctx.stats.pipelineV2DeployFirstBudgetReturned, 1)
end)

runTest("support_cover_without_occupied_target_is_staging_not_cover", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local state = stateWith({}, {{name = "Crusher", currentHp = 4, startingHp = 4}})
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Crusher",
        target = {row = 2, col = 3}
    }
    local supportCell = {
        key = "2,3",
        row = 2,
        col = 3,
        status = "free_target",
        value = 260,
        earlyPositionValue = 260,
        earlyPrimaryTarget = false,
        earlyFrontierRole = "support_cover",
        earlySupportForKey = "2,2",
        earlyCoverValueBonus = 120
    }
    local supportedCell = {
        key = "2,2",
        row = 2,
        col = 2,
        status = "free_target",
        value = 500,
        earlyPositionValue = 500,
        earlyPrimaryTarget = true,
        earlyFrontierRole = "frontier_target"
    }
    local ctx = baseCtx({
        realCover = true,
        strictSupportCover = true,
        deployEntries = {{action = deploy, cheapScore = 20}}
    })

    local generated = candidates.generateDeployFirst(nil, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {supportedCell, supportCell},
        nextExpansion = {},
        freeTop = {supportedCell, supportCell},
        top = {supportedCell, supportCell}
    }, {
        maxCandidates = 4,
        continuationCap = 0,
        earlySecondScanCap = 0
    })

    assertEquals(#generated, 1, "support-like deploy target should remain available as staging")
    assertEquals(generated[1].tacticalTags.earlyPositionReason, "staging_frontier")
    assertEquals(ctx.stats.pipelineV2DeployFirstReasonCounts.support_cover, nil)
    assertEquals(ctx.stats.pipelineV2DeployFirstReasonCounts.staging_frontier, 1)
end)

runTest("distance_cover_mode_keeps_move_approximation_available", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local mover = unit("Crusher", 1, 4, 4)
    local state = stateWith({unit("Crusher", 1, 2, 2), mover}, {})
    local move = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 3, col = 3}
    }
    local ctx = baseCtx({
        realCover = false,
        moveEntries = {{action = move, unit = mover, cheapScore = 0}}
    })

    local generated = candidates.generateMovePosition(nil, state, ctx, positionMap(), {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 1, "distance-approximate move cover mode should stay reversible")
    assertEquals(ctx.stats.pipelineV2MovePositionCoverMode, "distance_approx")
end)

runTest("move_cover_uses_after_move_influence", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local mover = unit("Crusher", 1, 4, 4)
    local state = stateWith({unit("Crusher", 1, 2, 2), mover}, {})
    local move = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        moveEntries = {{action = move, unit = mover, cheapScore = 0}}
    })

    local generated = candidates.generateMovePosition(nil, state, ctx, positionMap(), {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 1, "expected move to create real cover after repositioning")
    assertEquals(generated[1].tacticalTags.earlyPositionReason, "move_cover_owned_uncovered")
    assertEquals(ctx.stats.pipelineV2MovePositionRealCoverHits, 1, "real move cover hit should be counted")
    assertEquals(ctx.stats.pipelineV2UnitPoolFreeUnits, 1, "mover should be in the free unit pool")
    assertEquals(ctx.stats.pipelineV2UnitPoolLockedOccupants, 1, "uncovered occupant should stay structural")
    assertEquals(ctx.stats.pipelineV2UnitPoolCoverTargets, 1, "uncovered occupied cell should require cover")
    assertEquals(ctx.stats.pipelineV2UnitPoolResolvedCells, 0, "no occupied covered cell is resolved yet")
end)

runTest("owned_uncovered_can_advance_to_better_free_target", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local mover = unit("Crusher", 1, 2, 2)
    local state = stateWith({mover}, {})
    local move = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        uncoveredAdvance = true,
        uncoveredAdvanceMinGain = 60,
        formedPairRelease = false,
        moveEntries = {{action = move, unit = mover, cheapScore = 0}}
    })

    local generated = candidates.generateMovePosition(nil, state, ctx, positionMapWith(
        "owned_uncovered",
        160,
        "free_target",
        240
    ), {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 1, "uncovered structural unit should advance to a clearly better target")
    assertEquals(generated[1].tacticalTags.earlyPositionReason, "move_uncovered_occupy_better")
end)

runTest("owned_uncovered_does_not_advance_for_small_gain", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local mover = unit("Crusher", 1, 2, 2)
    local state = stateWith({mover}, {})
    local move = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        uncoveredAdvance = true,
        uncoveredAdvanceMinGain = 60,
        formedPairRelease = false,
        moveEntries = {{action = move, unit = mover, cheapScore = 0}}
    })

    local generated = candidates.generateMovePosition(nil, state, ctx, positionMapWith(
        "owned_uncovered",
        200,
        "free_target",
        230
    ), {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 0, "small positional gain should not abandon an occupied strategic cell")
    assertEquals(ctx.stats.pipelineV2MovePositionSkippedReasons.owned_uncovered_upgrade_too_small, 1)
end)

runTest("owned_covered_source_stays_locked", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local mover = unit("Crusher", 1, 2, 2)
    local state = stateWith({mover}, {})
    local move = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        uncoveredAdvance = true,
        formedPairRelease = false,
        moveEntries = {{action = move, unit = mover, cheapScore = 0}}
    })

    local generated = candidates.generateMovePosition(nil, state, ctx, positionMapWith(
        "owned_covered",
        300,
        "free_target",
        400
    ), {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 0, "covered structural cell should not be abandoned")
    assertEquals(ctx.stats.pipelineV2MovePositionSkippedReasons.source_cell_already_covered, 1)
end)

runTest("owned_source_stays_locked_even_when_outside_top_cells", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local mover = unit("Crusher", 1, 2, 2)
    local state = stateWith({mover}, {})
    local move = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        formedPairRelease = false,
        moveEntries = {{action = move, unit = mover, cheapScore = 0}}
    })
    local generated = candidates.generateMovePosition(nil, state, ctx, {
        cells = {
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 300},
            {key = "2,3", row = 2, col = 3, status = "free_target", value = 400}
        },
        ownedUncovered = {},
        ownedCovered = {},
        ownedCoveredAll = {
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 300}
        },
        freeTargets = {
            {key = "2,3", row = 2, col = 3, status = "free_target", value = 400}
        },
        nextExpansion = {},
        freeTop = {
            {key = "2,3", row = 2, col = 3, status = "free_target", value = 400}
        },
        top = {
            {key = "2,3", row = 2, col = 3, status = "free_target", value = 400}
        }
    }, {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 0, "occupied good cells must stay locked even outside the top-N summary")
    assertEquals(ctx.stats.pipelineV2MovePositionSkippedReasons.source_cell_already_covered, 1)
    assertEquals(ctx.stats.pipelineV2UnitPoolLockedOccupants, 1, "full owned-cell list should lock the occupant")
end)

runTest("covering_unit_can_reposition_only_if_coverage_preserved", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local occupant = unit("Crusher", 1, 2, 2)
    local cover = unit("Cloudstriker", 1, 2, 5)
    local state = stateWith({occupant, cover}, {})
    local move = {
        type = "move",
        unit = {row = cover.row, col = cover.col},
        target = {row = 2, col = 4}
    }
    local ctx = baseCtx({
        realCover = true,
        stableCover = true,
        coverReposition = true,
        formedPairRelease = false,
        moveEntries = {{action = move, unit = cover, cheapScore = 0}}
    })

    local generated = candidates.generateMovePosition(nil, state, ctx, positionMapWith(
        "owned_covered",
        300,
        "free_target",
        240,
        2,
        4
    ), {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 1, "covering unit may move only when it still covers the resolved cell")
    assertEquals(generated[1].tacticalTags.earlyPositionReason, "move_cover_reposition_preserves")
end)

runTest("covering_unit_cannot_expand_if_coverage_breaks", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local occupant = unit("Crusher", 1, 2, 2)
    local cover = unit("Cloudstriker", 1, 2, 5)
    local state = stateWith({occupant, cover}, {})
    local move = {
        type = "move",
        unit = {row = cover.row, col = cover.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        stableCover = true,
        coverReposition = true,
        formedPairRelease = false,
        moveEntries = {{action = move, unit = cover, cheapScore = 0}}
    })

    local generated = candidates.generateMovePosition(nil, state, ctx, positionMapWith(
        "owned_covered",
        300,
        "free_target",
        400,
        2,
        3
    ), {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 0, "covering unit should not move if it leaves the resolved cell uncovered")
    assertEquals(ctx.stats.pipelineV2MovePositionSkippedReasons.cover_reposition_breaks_resolved_cell, 1)
end)

runTest("move_position_releases_cover_when_no_stable_pair_action_exists", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local occupant = unit("Crusher", 1, 2, 2)
    local cover = unit("Crusher", 1, 2, 5)
    cover.atkRange = 3
    local state = stateWith({occupant, cover}, {})
    local move = {
        type = "move",
        unit = {row = cover.row, col = cover.col},
        target = {row = 3, col = 5}
    }
    local ctx = baseCtx({
        realCover = true,
        stableCover = true,
        coverReposition = true,
        moveEntries = {{action = move, unit = cover, cheapScore = 0}}
    })
    local generated = candidates.generateMovePosition(nil, state, ctx, {
        ownedCovered = {
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 500}
        },
        ownedUncovered = {},
        freeTargets = {
            {key = "3,5", row = 3, col = 5, status = "free_target", value = 220}
        },
        nextExpansion = {},
        freeTop = {
            {key = "3,5", row = 3, col = 5, status = "free_target", value = 220}
        },
        top = {
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 500},
            {key = "3,5", row = 3, col = 5, status = "free_target", value = 220}
        }
    }, {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 1, "release cover is allowed only as a no-normal-candidate fallback")
    assertEquals(
        generated[1].tacticalTags.earlyPositionReason,
        "move_release_cover_then_move_position_map_target"
    )
end)

runTest("move_position_forced_release_orders_by_destination_value", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local occupant = unit("Crusher", 1, 2, 2)
    local cover = unit("Crusher", 1, 2, 5)
    cover.atkRange = 3
    local state = stateWith({occupant, cover}, {})
    local badStep = {
        type = "move",
        unit = {row = cover.row, col = cover.col},
        target = {row = 1, col = 5}
    }
    local betterStep = {
        type = "move",
        unit = {row = cover.row, col = cover.col},
        target = {row = 3, col = 5}
    }
    local ctx = baseCtx({
        realCover = true,
        stableCover = true,
        coverReposition = true,
        strategicMinValue = 120,
        moveEntries = {
            {action = badStep, unit = cover, cheapScore = 0},
            {action = betterStep, unit = cover, cheapScore = 0}
        }
    })
    local covered = {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 500}
    local badTarget = {key = "1,5", row = 1, col = 5, status = "other", value = -80}
    local betterTarget = {key = "3,5", row = 3, col = 5, status = "other", value = 80}

    local generated = candidates.generateMovePosition(nil, state, ctx, {
        ownedCovered = {covered},
        ownedUncovered = {},
        freeTargets = {},
        nextExpansion = {},
        freeTop = {},
        top = {covered, badTarget, betterTarget}
    }, {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertTrue(#generated >= 1, "release fallback should still return candidates")
    assertEquals(
        generated[1].signature,
        "move:2,5>3,5",
        "forced release move-position should prefer the better destination"
    )
    assertEquals(
        generated[1].tacticalTags.earlyPositionReason,
        "move_release_cover_then_forced_step"
    )
end)

runTest("free_unit_can_expand_while_covered_pair_stays_stable", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local occupant = unit("Crusher", 1, 2, 2)
    local cover = unit("Cloudstriker", 1, 2, 5)
    local freeUnit = unit("Crusher", 1, 4, 4)
    local state = stateWith({occupant, cover, freeUnit}, {})
    local move = {
        type = "move",
        unit = {row = freeUnit.row, col = freeUnit.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        stableCover = true,
        coverReposition = true,
        moveEntries = {{action = move, unit = freeUnit, cheapScore = 0}}
    })

    local generated = candidates.generateMovePosition(nil, state, ctx, positionMapWith(
        "owned_covered",
        300,
        "free_target",
        400,
        2,
        3
    ), {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 1, "free units should be preferred for the next valuable cell")
    assertEquals(generated[1].tacticalTags.earlyPositionReason, "move_occupy_free_target")
    assertEquals(ctx.stats.pipelineV2UnitPoolFreeUnits, 1, "only the third unit should be free")
    assertEquals(ctx.stats.pipelineV2UnitPoolLockedOccupants, 1, "occupied covered cell should lock its occupant")
    assertEquals(ctx.stats.pipelineV2UnitPoolLockedCoverUnits, 1, "covering unit should be recognized")
    assertEquals(ctx.stats.pipelineV2UnitPoolCoverTargets, 0, "covered cell should no longer need cover")
    assertEquals(ctx.stats.pipelineV2UnitPoolResolvedCells, 1, "one occupied covered cell should be resolved")
end)

runTest("enemy_move_attack_free_target_is_not_an_early_move_target", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")
    local mover = unit("Crusher", 1, 2, 2)
    local state = stateWith({mover}, {})
    local move = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        stableCover = true,
        moveEntries = {{action = move, unit = mover, cheapScore = 0}}
    })
    local map = positionMapWith("other", 0, "free_target", 900, 2, 3)
    map.freeTargets[1].enemyMoveAttackCount = 1
    map.freeTargets[1].risk = {enemyMoveAttack = 1}

    assertEquals(
        earlyCellPolicy.rejectReason(map.freeTargets[1], ctx),
        "enemy_move_attack",
        "move-attack reach should reject an early strategic cell"
    )
    assertEquals(
        earlyCellPolicy.rejectReason({value = 900, risk = {enemyPunish = true}}, ctx),
        "enemy_punish",
        "explicit punish proof should also reject an early strategic cell"
    )

    local generated = candidates.generateMovePosition(nil, state, ctx, map, {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 1, "unsafe cells should only survive as penalized legal floor candidates")
    assertEquals(
        generated[1].tacticalTags.earlyPositionReason,
        "move_legal_floor_non_strategic",
        "punishable target must not be promoted as a normal early strategic move"
    )
    assertTrue(
        generated[1].cheapScore < 0,
        "punishable legal floor candidate should stay strongly penalized"
    )
    assertEquals(
        (ctx.stats.pipelineV2MovePositionSkippedReasons or {}).target_not_strategic or 0,
        1,
        "punishable target should be reported as non-strategic"
    )
end)

runTest("unit_pool_ignores_commandant_cells", function()
    local unitPool = require("ai_tournament.early_position_units")
    local hub = unit("Commandant", 1, 1, 1)
    local occupant = unit("Crusher", 1, 2, 2)
    local state = stateWith({hub, occupant}, {})
    local classified = unitPool.classify(nil, state, baseCtx(), {
        ownedUncovered = {
            {key = "1,1", row = 1, col = 1, status = "owned_uncovered", value = 900},
            {key = "2,2", row = 2, col = 2, status = "owned_uncovered", value = 300}
        },
        ownedCovered = {
            {key = "1,1", row = 1, col = 1, status = "owned_covered", value = 900}
        }
    })

    assertEquals(#classified.coverTargets, 1, "only normal occupied cells should request cover")
    assertEquals(#classified.resolvedCells, 0, "Commandant cells should not become early-position resolved cells")
    assertEquals(#classified.lockedOccupants, 1, "Commandant should not be locked as a structural mover")
end)

runTest("unit_pool_counts_other_owned_cell_occupant_as_cover", function()
    local unitPool = require("ai_tournament.early_position_units")
    local anchor = unit("Earthstalker", 1, 2, 2)
    local advanced = unit("Crusher", 1, 2, 3)
    local state = stateWith({anchor, advanced}, {})
    local classified = unitPool.classify(nil, state, baseCtx({strategicMinValue = 120}), {
        ownedCovered = {
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 500}
        },
        ownedUncovered = {
            {key = "2,3", row = 2, col = 3, status = "owned_uncovered", value = 49}
        }
    })

    assertEquals(#classified.resolvedCells, 1, "the anchor cell should still be resolved")
    assertEquals(#classified.lockedCoverUnits, 1, "a different owned-cell occupant can be support cover")
    assertEquals(#classified.releasableOccupants, 0, "a covering support unit should not also be releasable")
    assertTrue(classified.coveredCellsByUnitKey["2,3"] ~= nil, "advanced occupant should cover the anchor")
    assertTrue(classified.releasableByKey["2,3"] == nil, "cover role should win over low-value occupant release")
    assertTrue(classified.occupantCellByKey["2,3"] ~= nil, "advanced occupant should keep its cell value")
end)

runTest("unit_pool_counts_free_units_as_cover", function()
    local unitPool = require("ai_tournament.early_position_units")
    local anchor = unit("Earthstalker", 1, 2, 2)
    local support = unit("Crusher", 1, 2, 3)
    local state = stateWith({anchor, support}, {})
    local classified = unitPool.classify(nil, state, baseCtx({strategicMinValue = 120}), {
        ownedCovered = {
            {key = "2,2", row = 2, col = 2, status = "owned_covered", value = 500}
        },
        ownedUncovered = {}
    })

    assertEquals(#classified.lockedOccupants, 1, "resolved cell should lock its occupant")
    assertEquals(#classified.lockedCoverUnits, 1, "free support unit should count as cover")
    assertTrue(classified.coveredCellsByUnitKey["2,3"] ~= nil, "support unit should cover the anchor")
end)

runTest("early_second_orders_free_then_cover_then_occupant", function()
    local second = require("ai_tournament.early_position_second_action")
    local freeMove = {
        action = {type = "move", unit = {row = 4, col = 4}, target = {row = 4, col = 5}},
        unit = unit("Crusher", 1, 4, 4),
        cheapScore = 0
    }
    local coverMove = {
        action = {type = "move", unit = {row = 2, col = 3}, target = {row = 2, col = 4}},
        unit = unit("Crusher", 1, 2, 3),
        cheapScore = 0
    }
    local occupantMove = {
        action = {type = "move", unit = {row = 3, col = 3}, target = {row = 3, col = 4}},
        unit = unit("Crusher", 1, 3, 3),
        cheapScore = 0
    }
    local entries = {occupantMove, coverMove, freeMove}
    second._private.sortMoveEntriesForEarlySecond(entries, {
        coveredCellsByUnitKey = {
            ["2,3"] = {{key = "2,2", row = 2, col = 2, value = 300}}
        },
        releasableByKey = {
            ["3,3"] = {cell = {key = "3,3", row = 3, col = 3, value = 120}}
        },
        lockedOccupantByKey = {}
    }, nil)

    assertEquals(signature({entries[1].action}), "move:4,4>4,5", "free unit should be scanned first")
    assertEquals(signature({entries[2].action}), "move:2,3>2,4", "cover unit should be next")
    assertEquals(signature({entries[3].action}), "move:3,3>3,4", "occupant should be last")
end)

runTest("early_second_orders_locked_occupants_by_cell_value", function()
    local second = require("ai_tournament.early_position_second_action")
    local high = {
        action = {type = "move", unit = {row = 5, col = 5}, target = {row = 5, col = 6}},
        unit = unit("Crusher", 1, 5, 5),
        cheapScore = 0
    }
    local low = {
        action = {type = "move", unit = {row = 3, col = 3}, target = {row = 3, col = 4}},
        unit = unit("Crusher", 1, 3, 3),
        cheapScore = 0
    }
    local entries = {high, low}
    second._private.sortMoveEntriesForEarlySecond(entries, {
        lockedOccupantByKey = {
            ["3,3"] = "owned_covered",
            ["5,5"] = "owned_covered"
        },
        occupantCellByKey = {
            ["3,3"] = {key = "3,3", row = 3, col = 3, value = 120},
            ["5,5"] = {key = "5,5", row = 5, col = 5, value = 900}
        }
    }, nil)

    assertEquals(signature({entries[1].action}), "move:3,3>3,4", "lowest-value occupant should move first")
    assertEquals(signature({entries[2].action}), "move:5,5>5,6", "higher-value occupant should be preserved longer")
end)

runTest("unit_pool_releases_low_value_cells", function()
    local unitPool = require("ai_tournament.early_position_units")
    local low = unit("Crusher", 1, 2, 2)
    local good = unit("Crusher", 1, 3, 3)
    local state = stateWith({low, good}, {})
    local classified = unitPool.classify(nil, state, baseCtx({strategicMinValue = 120}), {
        ownedUncovered = {
            {key = "2,2", row = 2, col = 2, status = "owned_uncovered", value = 80},
            {key = "3,3", row = 3, col = 3, status = "owned_uncovered", value = 300}
        },
        ownedCovered = {}
    })

    assertEquals(#classified.coverTargets, 1, "only valuable cells should request cover")
    assertEquals(#classified.lockedOccupants, 1, "low value occupied cells should not lock the unit")
    assertEquals(#classified.releasableOccupants, 1, "low value occupied cells should be releasable")
    assertTrue(classified.releasableByKey["2,2"] ~= nil, "low value source should be tracked by key")
end)

runTest("unit_pool_releases_enemy_attackable_cells", function()
    local unitPool = require("ai_tournament.early_position_units")
    local contested = unit("Crusher", 1, 2, 2)
    local state = stateWith({contested}, {})
    local classified = unitPool.classify(nil, state, baseCtx({strategicMinValue = 120}), {
        ownedCovered = {
            {
                key = "2,2",
                row = 2,
                col = 2,
                status = "owned_covered",
                value = 400,
                enemyAttackCount = 1,
                directlyAttackableByEnemy = true
            }
        },
        ownedUncovered = {}
    })

    assertEquals(#classified.resolvedCells, 0, "directly attackable cells should not become resolved early cells")
    assertEquals(#classified.lockedOccupants, 0, "directly attackable cells should not lock occupants")
    assertEquals(#classified.releasableOccupants, 1, "directly attackable cells should be releasable")
end)

runTest("unit_pool_holds_occupied_cell_through_nonlethal_damage", function()
    local unitPool = require("ai_tournament.early_position_units")
    local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")
    local holder = unit("Crusher", 1, 2, 2)
    local state = stateWith({holder}, {})
    local ctx = baseCtx({strategicMinValue = 120})
    local occupiedCell = {
        key = "2,2",
        row = 2,
        col = 2,
        status = "owned_covered",
        value = 400,
        occupiedByUs = true,
        occupantHp = 4,
        enemyAttackCount = 1,
        directlyAttackableByEnemy = true,
        occupantEnemyBestReply = {damage = 3, expectedDamage = 3, lethal = false, kind = "direct_attack"}
    }

    assertTrue(
        earlyCellPolicy.isGoodStrategicCell(occupiedCell, ctx) == false,
        "strict free-cell policy should still reject the threatened cell"
    )
    assertTrue(
        earlyCellPolicy.isHoldableOccupiedStrategicCell(occupiedCell, ctx) == true,
        "occupied policy should allow holding non-lethal damage"
    )

    local classified = unitPool.classify(nil, state, ctx, {
        ownedCovered = {occupiedCell},
        ownedUncovered = {}
    })

    assertEquals(#classified.resolvedCells, 1, "non-lethal damage should keep the occupied cell resolved")
    assertEquals(#classified.lockedOccupants, 1, "holder should stay locked on the strategic cell")
    assertEquals(#classified.releasableOccupants, 0, "holder should not be released for non-lethal damage")
end)

runTest("nonlethal_threatened_occupied_cell_raises_cover_priority", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local mover = unit("Crusher", 1, 1, 1)
    local threatenedHolder = unit("Crusher", 1, 2, 2)
    local stableHolder = unit("Crusher", 1, 4, 2)
    local state = stateWith({mover, threatenedHolder, stableHolder}, {})
    local coverThreatened = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 2, col = 3}
    }
    local coverStable = {
        type = "move",
        unit = {row = mover.row, col = mover.col},
        target = {row = 4, col = 3}
    }
    local ctx = baseCtx({
        realCover = false,
        holdThreatCoverBonus = 180,
        moveEntries = {
            {action = coverStable, unit = mover, cheapScore = 0},
            {action = coverThreatened, unit = mover, cheapScore = 0}
        }
    })
    local threatenedCell = {
        key = "2,2",
        row = 2,
        col = 2,
        status = "owned_uncovered",
        value = 300,
        occupiedByUs = true,
        occupantHp = 4,
        enemyAttackCount = 1,
        directlyAttackableByEnemy = true,
        occupantEnemyBestReply = {damage = 3, expectedDamage = 3, lethal = false, kind = "direct_attack"}
    }
    local stableCell = {
        key = "4,2",
        row = 4,
        col = 2,
        status = "owned_uncovered",
        value = 420,
        occupiedByUs = true
    }

    local generated = candidates.generateMovePosition(nil, state, ctx, {
        ownedUncovered = {threatenedCell, stableCell},
        ownedUncoveredAll = {threatenedCell, stableCell},
        ownedCovered = {},
        freeTargets = {},
        nextExpansion = {},
        freeTop = {},
        top = {stableCell, threatenedCell}
    }, {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertTrue(#generated >= 2, "both cover moves should be generated")
    assertEquals(generated[1].tacticalTags.earlyPositionReason, "move_cover_owned_uncovered")
    assertEquals(generated[1].tacticalTags.earlyPositionTarget.row, 2, "threatened occupied cell should win cover priority")
    assertEquals(generated[1].tacticalTags.earlyPositionTarget.col, 2, "threatened occupied cell should win cover priority")
end)

runTest("unit_pool_releases_occupied_cell_when_threat_kills", function()
    local unitPool = require("ai_tournament.early_position_units")
    local lethalHolder = unit("Crusher", 1, 2, 2)
    local state = stateWith({lethalHolder}, {})
    local ctx = baseCtx({strategicMinValue = 120})

    local classified = unitPool.classify(nil, state, ctx, {
        ownedCovered = {
            {
                key = "2,2",
                row = 2,
                col = 2,
                status = "owned_covered",
                value = 400,
                occupiedByUs = true,
                occupantHp = 1,
                enemyAttackCount = 1,
                directlyAttackableByEnemy = true,
                occupantEnemyBestReply = {damage = 1, expectedDamage = 1, kind = "direct_attack"}
            }
        },
        ownedUncovered = {}
    })

    assertEquals(#classified.resolvedCells, 0, "lethal threats should not remain resolved")
    assertEquals(#classified.lockedOccupants, 0, "lethal occupied cells should not lock occupants")
    assertEquals(#classified.releasableOccupants, 1, "lethal occupied cells should remain movable")
end)

runTest("unit_pool_releases_hidden_lethal_reply_even_when_cell_looks_safe", function()
    local unitPool = require("ai_tournament.early_position_units")
    local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")
    local holder = unit("Crusher", 1, 2, 2)
    holder.currentHp = 2
    local state = stateWith({holder}, {})
    local ctx = baseCtx({strategicMinValue = 120, earlyRetreat = true})
    local cell = {
        key = "2,2",
        row = 2,
        col = 2,
        status = "owned_uncovered",
        value = 400,
        occupiedByUs = true,
        occupantHp = 2,
        occupantEnemyBestReply = {damage = 2, expectedDamage = 2, lethal = true, kind = "move_attack"}
    }

    assertTrue(
        earlyCellPolicy.isGoodStrategicCell(cell, ctx) == true,
        "strict free-cell signals may still miss a hidden reply"
    )
    assertTrue(
        earlyCellPolicy.isHoldableOccupiedStrategicCell(cell, ctx) == false,
        "lethal reply should override holdability for an occupied cell"
    )
    assertEquals(earlyCellPolicy.rejectReason(cell, ctx), "enemy_lethal_reply")

    local classified = unitPool.classify(nil, state, ctx, {
        ownedUncovered = {cell},
        ownedCovered = {}
    })

    assertEquals(#classified.lockedOccupants, 0, "hidden lethal reply should not lock the occupant")
    assertEquals(#classified.releasableOccupants, 1, "hidden lethal reply should make the unit movable")
    assertTrue(classified.releasableByKey["2,2"] ~= nil, "retreat source should be tracked as releasable")

    local offCtx = baseCtx({strategicMinValue = 120, earlyRetreat = false})
    assertTrue(
        earlyCellPolicy.isHoldableOccupiedStrategicCell(cell, offCtx) == true,
        "flag off restores previous hold behavior"
    )
end)

runTest("move_position_prioritizes_retreat_from_lethal_reply", function()
    local candidates = require("ai_tournament.early_position_candidates")
    local exposed = unit("Crusher", 1, 2, 2)
    exposed.currentHp = 2
    local state = stateWith({exposed}, {})
    local retreatMove = {
        type = "move",
        unit = {row = exposed.row, col = exposed.col},
        target = {row = 2, col = 3}
    }
    local ctx = baseCtx({
        realCover = true,
        earlyRetreat = true,
        retreatScoreBonus = 900,
        moveEntries = {{action = retreatMove, unit = exposed, cheapScore = 0}}
    })
    local source = {
        key = "2,2",
        row = 2,
        col = 2,
        status = "owned_uncovered",
        value = 400,
        occupiedByUs = true,
        occupantHp = 2,
        occupantEnemyBestReply = {damage = 2, expectedDamage = 2, lethal = true, kind = "move_attack"}
    }
    local target = {
        key = "2,3",
        row = 2,
        col = 3,
        status = "free_target",
        value = 260
    }

    local generated = candidates.generateMovePosition(nil, state, ctx, {
        ownedUncovered = {source},
        ownedUncoveredAll = {source},
        ownedCovered = {},
        freeTargets = {target},
        nextExpansion = {},
        freeTop = {target},
        top = {source, target}
    }, {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 1, "lethal reply should create a retreat candidate")
    assertEquals(generated[1].signature, "move:2,2>2,3")
    assertEquals(generated[1].tacticalTags.earlyPositionReason, "move_retreat_to_strategic_cell")
    assertEquals(ctx.stats.pipelineV2MovePositionReasonCounts.move_retreat_to_strategic_cell, 1)
    assertTrue(
        generated[1].cheapScore > target.value,
        "retreat bonus should lift the move above ordinary expansion"
    )
end)

runTest("unit_pool_locks_cells_by_strategic_value_before_state_penalty", function()
    local unitPool = require("ai_tournament.early_position_units")
    local occupant = unit("Crusher", 1, 2, 2)
    local state = stateWith({occupant}, {})
    local classified = unitPool.classify(nil, state, baseCtx({strategicMinValue = 120}), {
        ownedCovered = {
            {
                key = "2,2",
                row = 2,
                col = 2,
                status = "owned_covered",
                value = -20,
                earlyStrategicValue = 300
            }
        },
        ownedUncovered = {}
    })

    assertEquals(#classified.resolvedCells, 1, "state penalty should not erase a valuable stable cell")
    assertEquals(#classified.lockedOccupants, 1, "valuable stable cells should still lock occupants")
    assertEquals(#classified.releasableOccupants, 0, "valuable stable cells should not be releasable")
end)

runTest("early_gate_allows_only_full_new_position_unforced_retreat", function()
    local brain = require("ai_tournament.brain")
    local ctx = {
        maxActions = 2,
        cfg = {
            EARLY_GATE_ALLOW_PIPELINE_V2_POSITIONAL_RETREAT = true
        }
    }
    local candidate = {
        source = "early_position_move",
        actions = {
            {type = "move", unit = {row = 2, col = 2}, target = {row = 2, col = 3}},
            {type = "move", unit = {row = 3, col = 2}, target = {row = 3, col = 3}}
        },
        containsAttack = false,
        hasFactionAttack = false,
        tacticalTags = {
            earlyPositionReason = "move_occupy_free_target_then_position"
        }
    }

    assertTrue(
        brain.pipelineV2EarlyPositionRetreatAllowedForGate(ctx, {candidate = candidate}) == true,
        "full new early-position candidates should bypass only the unforced-retreat veto"
    )

    ctx.cfg.EARLY_GATE_ALLOW_PIPELINE_V2_POSITIONAL_RETREAT = false
    assertTrue(
        brain.pipelineV2EarlyPositionRetreatAllowedForGate(ctx, {candidate = candidate}) == false,
        "flag off should restore the old unforced-retreat veto"
    )

    ctx.cfg.EARLY_GATE_ALLOW_PIPELINE_V2_POSITIONAL_RETREAT = true
    candidate.actions = {candidate.actions[1]}
    assertTrue(
        brain.pipelineV2EarlyPositionRetreatAllowedForGate(ctx, {candidate = candidate}) == false,
        "short positional candidates must not pass the gate relaxation"
    )

    candidate.actions = {
        {type = "move", unit = {row = 2, col = 2}, target = {row = 2, col = 3}},
        {type = "attack", unit = {row = 2, col = 3}, target = {row = 2, col = 4}}
    }
    candidate.containsAttack = true
    assertTrue(
        brain.pipelineV2EarlyPositionRetreatAllowedForGate(ctx, {candidate = candidate}) == false,
        "attack candidates must stay under the tactical gates"
    )
end)

runTest("early_move_legal_floor_keeps_legal_move_when_no_strategic_targets", function()
    local candidatesModule = require("ai_tournament.early_position_candidates")
    local mover = unit("Wingstalker", 1, 4, 4)
    local state = stateWith({mover}, {})
    local move = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 4, col = 5}
    }
    local lowValueCell = {key = "4,5", row = 4, col = 5, status = "other", value = 20}
    local ctx = baseCtx({
        strategicMinValue = 120,
        earlyLegalFloor = true,
        earlyLegalFloorPenalty = 100,
        moveEntries = {{action = move, unit = mover, cheapScore = 10}}
    })

    local generated = candidatesModule.generateMovePosition(nil, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {},
        nextExpansion = {},
        freeTop = {},
        top = {lowValueCell}
    }, {
        maxCandidates = 4,
        continuationCap = 0
    })

    assertEquals(#generated, 1, "legal floor should keep a scored legal move instead of returning no candidates")
    assertEquals(
        generated[1].tacticalTags.earlyPositionReason,
        "move_legal_floor_non_strategic",
        "floor candidate should be explicit in diagnostics"
    )
    assertTrue(generated[1].tacticalTags.earlyPositionLegalFloor == true, "floor candidate should be tagged")
    assertEquals(ctx.stats.pipelineV2MovePositionLegalFloorPromoted, 1)
end)

runTest("full_turn_exact_sanitize_filters_bad_second_and_keeps_alternative", function()
    local fullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local deployedSupply = {name = "Cloudstriker", currentHp = 4, startingHp = 4}
    local mover = unit("Wingstalker", 1, 4, 4)
    local state = stateWith({mover}, {deployedSupply})
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Cloudstriker",
        target = {row = 1, col = 2}
    }
    local badSecond = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 4, col = 5}
    }
    local goodSecond = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 5, col = 4}
    }
    local badCell = {key = "4,5", row = 4, col = 5, status = "free_target", value = 600}
    local goodCell = {key = "5,4", row = 5, col = 4, status = "free_target", value = 320}
    local ctx = baseCtx({
        fullTurnExactSanitize = true,
        fullTurnForcedSecond = true,
        strategicMinValue = 120,
        moveEntries = {
            {action = badSecond, unit = mover, cheapScore = 20},
            {action = goodSecond, unit = mover, cheapScore = 10}
        }
    })
    local ai = {
        sanitizeActionSequenceForState = function(_, _, actions)
            local second = actions and actions[2] or nil
            if second and second.target and second.target.row == 4 and second.target.col == 5 then
                return {actions[1]}, {replacements = 1, reasonCounts = {test_rewrite = 1}}
            end
            return actions, {replacements = 0, reasonCounts = {}}
        end
    }
    local candidate = {
        actions = {deploy},
        signature = signature({deploy}),
        source = "early_position_deploy_first",
        buckets = {"occupy_free_target"},
        cheapScore = 300,
        tacticalTags = {
            earlyPositionReason = "occupy_free_target",
            earlyPositionTarget = {key = "1,2", row = 1, col = 2, status = "free_target", value = 300}
        }
    }

    local completed, stats = fullTurn.complete(ai, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {badCell, goodCell},
        nextExpansion = {},
        freeTop = {badCell, goodCell},
        top = {badCell, goodCell}
    }, {candidate}, {
        requiredActions = 2,
        scanCap = 4,
        maxCompletions = 2,
        minOutput = 5
    })

    assertEquals(#completed, 1, "exact sanitize filter should keep the valid alternate completion")
    assertEquals(signature({completed[1].actions[2]}), "move:4,4>5,4")
    assertEquals(stats.exactSanitizeRejected, 1, "bad completion should be rejected before runtime")
    assertEquals(stats.exactSanitizeRejectedReasons.test_rewrite, 1)
end)

runTest("full_turn_exact_sanitize_drops_existing_full_turn_rewrite", function()
    local fullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local mover = unit("Wingstalker", 1, 4, 4)
    local state = stateWith({mover}, {})
    local first = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 4, col = 5}
    }
    local second = {
        type = "move",
        unit = {row = 4, col = 5},
        target = {row = 4, col = 6}
    }
    local ctx = baseCtx({
        fullTurnExactSanitize = true,
        strategicMinValue = 120
    })
    local ai = {
        sanitizeActionSequenceForState = function(_, _, actions)
            return {actions[1]}, {replacements = 1, reasonCounts = {test_rewrite = 1}}
        end
    }
    local candidate = {
        actions = {first, second},
        signature = signature({first, second}),
        source = "early_position_move",
        buckets = {"move_occupy_free_target"},
        cheapScore = 300,
        tacticalTags = {
            earlyPositionReason = "move_occupy_free_target_then_position"
        }
    }

    local completed, stats = fullTurn.complete(ai, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {},
        nextExpansion = {},
        freeTop = {},
        top = {}
    }, {candidate}, {
        requiredActions = 2,
        maxCompletions = 0,
        minOutput = 1
    })

    assertEquals(#completed, 0, "rewritten full-turn candidates should not leak to runtime")
    assertEquals(stats.droppedReasons.existing_full_turn_sanitize_rejected, 1)
    assertEquals(stats.exactSanitizeRejectedReasons.test_rewrite, 1)
end)

runTest("full_turn_completion_forces_second_v2_move_when_strict_completion_misses", function()
    local fullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local firstMover = unit("Crusher", 1, 2, 2)
    local filler = unit("Cloudstriker", 1, 4, 4)
    local state = stateWith({firstMover, filler}, {})
    local strategic = {key = "2,3", row = 2, col = 3, status = "free_target", value = 300}
    local first = {
        type = "move",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }
    local second = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 4, col = 5}
    }
    local ctx = baseCtx({
        fullTurnForcedSecond = true,
        strategicMinValue = 120,
        moveEntries = {{action = second, unit = filler, cheapScore = 10}}
    })
    local candidate = {
        actions = {first},
        signature = signature({first}),
        source = "early_position_move",
        buckets = {"move_occupy_free_target"},
        cheapScore = 300,
        tacticalTags = {
            earlyPositionReason = "move_occupy_free_target",
            earlyPositionTarget = strategic
        }
    }

    local completed, stats = fullTurn.complete(nil, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {strategic},
        nextExpansion = {},
        freeTop = {strategic},
        top = {strategic}
    }, {candidate}, {
        requiredActions = 2,
        scanCap = 4,
        maxCompletions = 2,
        minOutput = 5
    })

    assertEquals(#completed, 1, "forced V2 second move should complete the candidate")
    assertEquals(#completed[1].actions, 2, "completed candidate should have a full two-action turn")
    assertEquals(completed[1].actions[2].target.row, 4)
    assertEquals(completed[1].actions[2].target.col, 5)
    assertEquals(
        completed[1].tacticalTags.earlyPositionReason,
        "move_occupy_free_target_then_complete_forced_free_step"
    )
    assertEquals(stats.reasonCounts.complete_forced_free_step, 1)
    assertEquals(stats.droppedReasons.no_v2_second_action, nil)
end)

runTest("full_turn_forced_second_orders_by_destination_value", function()
    local fullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local firstMover = unit("Crusher", 1, 2, 2)
    local filler = unit("Cloudstriker", 1, 4, 4)
    local state = stateWith({firstMover, filler}, {})
    local strategic = {key = "2,3", row = 2, col = 3, status = "free_target", value = 300}
    local badTarget = {key = "4,5", row = 4, col = 5, status = "other", value = -80}
    local betterTarget = {key = "5,4", row = 5, col = 4, status = "other", value = 80}
    local first = {
        type = "move",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }
    local badSecond = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 4, col = 5}
    }
    local betterSecond = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 5, col = 4}
    }
    local ctx = baseCtx({
        fullTurnForcedSecond = true,
        strategicMinValue = 120,
        moveEntries = {
            {action = badSecond, unit = filler, cheapScore = 0},
            {action = betterSecond, unit = filler, cheapScore = 0}
        }
    })
    local candidate = {
        actions = {first},
        signature = signature({first}),
        source = "early_position_move",
        buckets = {"move_occupy_free_target"},
        cheapScore = 300,
        tacticalTags = {
            earlyPositionReason = "move_occupy_free_target",
            earlyPositionTarget = strategic
        }
    }

    local completed = fullTurn.complete(nil, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {strategic},
        nextExpansion = {},
        freeTop = {strategic},
        top = {strategic, badTarget, betterTarget}
    }, {candidate}, {
        requiredActions = 2,
        scanCap = 1,
        maxCompletions = 2,
        minOutput = 5
    })

    assertEquals(#completed, 1, "forced completion should still complete the candidate")
    assertEquals(
        signature({completed[1].actions[2]}),
        "move:4,4>5,4",
        "forced full-turn completion should scan the better destination first"
    )
    assertEquals(
        completed[1].tacticalTags.earlyPositionReason,
        "move_occupy_free_target_then_complete_forced_free_step"
    )
end)

runTest("full_turn_forced_second_flag_off_restores_closed_drop", function()
    local fullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local firstMover = unit("Crusher", 1, 2, 2)
    local filler = unit("Cloudstriker", 1, 4, 4)
    local state = stateWith({firstMover, filler}, {})
    local strategic = {key = "2,3", row = 2, col = 3, status = "free_target", value = 300}
    local first = {
        type = "move",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }
    local second = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 4, col = 5}
    }
    local ctx = baseCtx({
        fullTurnForcedSecond = false,
        fullTurnTechnicalSecond = false,
        strategicMinValue = 120,
        moveEntries = {{action = second, unit = filler, cheapScore = 10}}
    })
    local candidate = {
        actions = {first},
        signature = signature({first}),
        source = "early_position_move",
        buckets = {"move_occupy_free_target"},
        cheapScore = 300,
        tacticalTags = {
            earlyPositionReason = "move_occupy_free_target",
            earlyPositionTarget = strategic
        }
    }

    local completed, stats = fullTurn.complete(nil, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {strategic},
        nextExpansion = {},
        freeTop = {strategic},
        top = {strategic}
    }, {candidate}, {
        requiredActions = 2,
        scanCap = 4,
        maxCompletions = 2,
        minOutput = 5
    })

    assertEquals(#completed, 0, "flag off should preserve the previous fail-closed behavior")
    assertEquals(stats.droppedReasons.no_v2_second_action, 1)
end)

runTest("full_turn_forced_deploy_second_completes_without_technical_fallback", function()
    local fullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local firstMover = unit("Crusher", 1, 2, 2)
    local state = stateWith({firstMover}, {
        {name = "Cloudstriker", currentHp = 4, startingHp = 4}
    })
    local strategic = {key = "2,3", row = 2, col = 3, status = "free_target", value = 300}
    local first = {
        type = "move",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Cloudstriker",
        target = {row = 1, col = 2}
    }
    local ctx = baseCtx({
        fullTurnForcedSecond = true,
        fullTurnForcedDeploySecond = true,
        fullTurnTechnicalSecond = false,
        strategicMinValue = 120,
        deployEntries = {{action = deploy, cheapScore = 50}},
        moveEntries = {}
    })
    local candidate = {
        actions = {first},
        signature = signature({first}),
        source = "early_position_move",
        buckets = {"move_occupy_free_target"},
        cheapScore = 300,
        tacticalTags = {
            earlyPositionReason = "move_occupy_free_target",
            earlyPositionTarget = strategic
        }
    }

    local completed, stats = fullTurn.complete(nil, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {strategic},
        nextExpansion = {},
        freeTop = {strategic},
        top = {strategic}
    }, {candidate}, {
        requiredActions = 2,
        scanCap = 4,
        maxCompletions = 2,
        minOutput = 5
    })

    assertEquals(#completed, 1, "forced deploy second should complete before the technical net")
    assertEquals(#completed[1].actions, 2, "forced deploy completion should return a full turn")
    assertEquals(completed[1].actions[2].type, "supply_deploy")
    assertEquals(
        completed[1].tacticalTags.earlyPositionReason,
        "move_occupy_free_target_then_complete_forced_deploy_reserve"
    )
    assertEquals(stats.reasonCounts.complete_forced_deploy_reserve, 1)
    assertEquals(stats.forcedDeploySecondAccepted, 1)
    assertEquals(stats.technicalSecondAccepted, 0)
    assertEquals(stats.droppedReasons.no_v2_second_action, nil)
end)

runTest("full_turn_technical_second_completes_with_deploy_before_sanitizer", function()
    local fullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local firstMover = unit("Crusher", 1, 2, 2)
    local state = stateWith({firstMover}, {
        {name = "Cloudstriker", currentHp = 4, startingHp = 4}
    })
    local strategic = {key = "2,3", row = 2, col = 3, status = "free_target", value = 300}
    local first = {
        type = "move",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Cloudstriker",
        target = {row = 1, col = 2}
    }
    local ctx = baseCtx({
        fullTurnForcedSecond = true,
        fullTurnForcedDeploySecond = false,
        fullTurnTechnicalSecond = true,
        fullTurnTechnicalSecondScanCap = 4,
        strategicMinValue = 120,
        deployEntries = {{action = deploy, cheapScore = 50}},
        moveEntries = {}
    })
    local candidate = {
        actions = {first},
        signature = signature({first}),
        source = "early_position_move",
        buckets = {"move_occupy_free_target"},
        cheapScore = 300,
        tacticalTags = {
            earlyPositionReason = "move_occupy_free_target",
            earlyPositionTarget = strategic
        }
    }

    local completed, stats = fullTurn.complete(nil, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {strategic},
        nextExpansion = {},
        freeTop = {strategic},
        top = {strategic}
    }, {candidate}, {
        requiredActions = 2,
        scanCap = 4,
        maxCompletions = 2,
        minOutput = 5
    })

    assertEquals(#completed, 1, "technical V2 second should complete before external sanitizer")
    assertEquals(#completed[1].actions, 2, "technical completion should still return a full turn")
    assertEquals(completed[1].actions[2].type, "supply_deploy")
    assertEquals(
        completed[1].tacticalTags.earlyPositionReason,
        "move_occupy_free_target_then_complete_technical_deploy_step"
    )
    assertEquals(stats.reasonCounts.complete_technical_deploy_step, 1)
    assertEquals(stats.technicalSecondAccepted, 1)
    assertEquals(stats.droppedReasons.no_v2_second_action, nil)
end)

runTest("move_pattern_penalty_tags_and_scores_recent_reversals", function()
    local movePatternPenalty = require("ai_tournament.move_pattern_penalty")
    local mover = unit("Wingstalker", 1, 2, 2)
    local state = stateWith({mover}, {})
    local ctx = baseCtx({
        positionPatternPenaltyCap = 120
    })
    local action = {
        type = "move",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }
    local ai = {
        getRepeatedLowImpactPatternPenalty = function(_, observedState, observedUnit, movePos, playerId)
            assertEquals(observedState, state)
            assertEquals(observedUnit.name, "Wingstalker")
            assertEquals(movePos.row, 2)
            assertEquals(movePos.col, 3)
            assertEquals(playerId, 1)
            return 180
        end
    }

    local adjusted, applied = movePatternPenalty.adjustScore(ai, state, ctx, action, 300)
    assertEquals(applied, 120)
    assertEquals(adjusted, 180)
    movePatternPenalty.tagPositionMoves({action})
    assertEquals(action._aiTag, "STRATEGIC_PLAN_MOVE")
end)

runTest("early_forced_move_value_penalizes_owned_cell_churn", function()
    local forcedMoveValue = require("ai_tournament.early_forced_move_value")
    local ctx = baseCtx({
        strategicMinValue = 120,
        earlyForcedOwnedCellChurnPenalty = 240
    })
    local action = {
        type = "move",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 2}
    }

    local ownedScore = forcedMoveValue.scoreTarget({
        row = 2,
        col = 2,
        status = "owned_uncovered",
        value = 200
    }, action, ctx)
    local freeScore = forcedMoveValue.scoreTarget({
        row = 2,
        col = 2,
        status = "free_target",
        value = 200
    }, action, ctx)

    assertEquals(ownedScore, -40)
    assertEquals(freeScore, 200)
end)

runTest("early_gate_rejects_v2_technical_completion_reasons_by_default", function()
    local earlyGate = require("ai_tournament.pipeline_v2_early_gate")
    local move = {
        type = "move",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }
    local deploy = {
        type = "supply_deploy",
        unitIndex = 1,
        unitName = "Cloudstriker",
        target = {row = 1, col = 2}
    }
    local ctx = baseCtx({
        strategicMinValue = 120
    })
    ctx.phase = {early = true}
    ctx.earlyPlan = {active = true}
    ctx.maxActions = 2
    ctx.cfg.PIPELINE_V2_REQUIRE_FULL_TURN_CANDIDATES = true
    local candidate = {
        source = "early_position_move",
        actions = {move, deploy},
        containsAttack = false,
        tacticalTags = {
            earlyPositionReason = "move_staging_frontier_then_complete_technical_deploy_step",
            earlyPositionTarget = {key = "2,3", row = 2, col = 3, status = "free_target", value = 300}
        }
    }

    local rejected, reason = earlyGate.rejects(nil, {}, ctx, {}, {candidate = candidate})

    assertEquals(rejected, true, "technical second should not pass the V2 early gate by default")
    assertEquals(reason, "v2_early_gate_unknown_position_reason")
    assertEquals(ctx.stats.pipelineV2EarlyGateAccepted, nil)
    assertEquals(ctx.stats.pipelineV2EarlyGateRejected, 1)
end)

runTest("early_gate_keeps_low_value_targets_as_scored_candidates", function()
    local earlyGate = require("ai_tournament.pipeline_v2_early_gate")
    local move = {
        type = "move",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }
    local support = {
        type = "move",
        unit = {row = 3, col = 2},
        target = {row = 3, col = 3}
    }
    local ctx = baseCtx({
        strategicMinValue = 120
    })
    ctx.phase = {early = true}
    ctx.earlyPlan = {active = true}
    ctx.maxActions = 2
    ctx.cfg.PIPELINE_V2_REQUIRE_FULL_TURN_CANDIDATES = true
    local candidate = {
        source = "early_position_move",
        actions = {move, support},
        containsAttack = false,
        tacticalTags = {
            earlyPositionReason = "move_staging_frontier_then_position",
            earlyPositionTarget = {key = "2,3", row = 2, col = 3, status = "free_target", value = 40}
        }
    }

    local rejected, reason = earlyGate.rejects(nil, {}, ctx, {}, {candidate = candidate})

    assertEquals(rejected, false, "low-value targets should remain legal scored candidates")
    assertEquals(reason, nil)
    assertTrue(candidate.tacticalTags.earlyPositionLowValueTarget == true, "candidate should be tagged for scoring")
    assertEquals(ctx.stats.pipelineV2EarlyGateAccepted, 1)
    assertEquals(ctx.stats.pipelineV2EarlyGateLowValueSoftened, 1)
end)

runTest("full_turn_retry_keeps_alternative_for_covered_first_action", function()
    local fullTurn = require("ai_tournament.pipeline_v2_full_turn")
    local firstMover = unit("Wingstalker", 1, 2, 2)
    local support = unit("Cloudstriker", 1, 4, 4)
    local state = stateWith({firstMover, support}, {})
    local primary = {key = "2,3", row = 2, col = 3, status = "free_target", value = 420}
    local supportTarget = {key = "4,5", row = 4, col = 5, status = "free_target", value = 260}
    local first = {
        type = "move",
        unit = {row = 2, col = 2},
        target = {row = 2, col = 3}
    }
    local badSecond = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 4, col = 3}
    }
    local goodSecond = {
        type = "move",
        unit = {row = 4, col = 4},
        target = {row = 4, col = 5}
    }
    local ctx = baseCtx({
        strategicMinValue = 120,
        moveEntries = {{action = goodSecond, unit = support, cheapScore = 10}}
    })
    local fullCandidate = {
        actions = {first, badSecond},
        signature = signature({first, badSecond}),
        source = "early_position_move",
        buckets = {"move_occupy_free_target"},
        cheapScore = 500,
        tacticalTags = {
            earlyPositionReason = "move_occupy_free_target_then_position",
            earlyPositionTarget = primary
        }
    }
    local singleCandidate = {
        actions = {first},
        signature = signature({first}),
        source = "early_position_move",
        buckets = {"move_occupy_free_target"},
        cheapScore = 480,
        tacticalTags = {
            earlyPositionReason = "move_occupy_free_target",
            earlyPositionTarget = primary
        }
    }

    local completed, stats = fullTurn.complete(nil, state, ctx, {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {primary, supportTarget},
        nextExpansion = {},
        freeTop = {primary, supportTarget},
        top = {primary, supportTarget}
    }, {fullCandidate, singleCandidate}, {
        requiredActions = 2,
        scanCap = 4,
        maxCompletions = 2,
        minCompletedAlternatives = 1,
        minOutput = 5
    })

    assertEquals(#completed, 2, "retry completion should keep the existing full turn and one alternative")
    assertEquals(stats.completed, 1, "covered first action should still get one alternative completion")
    local foundAlternative = false
    for _, candidate in ipairs(completed) do
        local secondAction = candidate.actions and candidate.actions[2] or nil
        if secondAction
            and secondAction.target
            and secondAction.target.row == 4
            and secondAction.target.col == 5 then
            foundAlternative = true
            break
        end
    end
    assertTrue(foundAlternative, "retry completion should include the alternative second action")
    assertEquals(stats.droppedReasons.covered_by_existing_full_turn, nil)
end)

runTest("early_position_primary_targets_keep_min_spacing", function()
    local map = require("ai_tournament.early_position_map")
    local policy = require("ai_tournament.early_position_cell_policy")
    local private = map._private
    local cells = {
        {key = "3,3", row = 3, col = 3, status = "free_target", value = 900, reachable = true},
        {key = "3,4", row = 3, col = 4, status = "free_target", value = 850, reachable = true},
        {key = "5,3", row = 5, col = 3, status = "next_expansion", value = 700, reachable = true},
        {key = "5,4", row = 5, col = 4, status = "free_target", value = 650, reachable = true}
    }

    local selected, meta = private.spacedTopCells(cells, 4, private.reachablePrimaryTarget, 2)
    local suppressed = private.markPrimaryTargets(cells, private.reachablePrimaryTarget, meta.selectedByKey, true)

    assertEquals(#selected, 2, "adjacent primary cells should not all survive spacing")
    assertEquals(selected[1].key, "3,3", "highest value target should survive")
    assertEquals(selected[2].key, "5,3", "next target should be at least two cells away")
    assertEquals(cells[2].earlyPrimaryTarget, false, "adjacent target should be demoted from primary")
    assertEquals(cells[4].earlyPrimaryTarget, false, "adjacent-to-selected later target should also be demoted")
    assertEquals(suppressed, 2, "suppressed count should include non-primary reachable targets")
    assertTrue(policy.isGoodStrategicCell(cells[1], {cfg = {}}), "primary target should remain strategic")
    assertTrue(not policy.isGoodStrategicCell(cells[2], {cfg = {}}), "demoted target should not generate primary occupation")
    assertEquals(policy.rejectReason(cells[2], {cfg = {}}), "primary_target_spacing", "reject reason should explain spacing")
end)

runTest("early_position_frontier_turns_behind_cells_into_support", function()
    local frontier = require("ai_tournament.early_position_frontier")
    local policy = require("ai_tournament.early_position_cell_policy")
    local ctx = {
        cfg = {
            EARLY_POSITION_FRONTIER_ENABLED = true,
            EARLY_POSITION_FRONTIER_SUPPORT_RADIUS = 2,
            EARLY_POSITION_FRONTIER_SUPPORT_TARGET_PENALTY = 90,
            EARLY_POSITION_FRONTIER_SUPPORT_COVER_BONUS = 150,
            EARLY_POSITION_FRONTIER_REAR_TARGET_PENALTY = 160,
            EARLY_POSITION_FRONTIER_REAR_COVER_BONUS = 55
        }
    }
    local primary = {
        key = "4,4",
        row = 4,
        col = 4,
        status = "free_target",
        value = 500,
        earlyStrategicValue = 500,
        progress = 4,
        reachable = true,
        earlyPrimaryTarget = true
    }
    local support = {
        key = "3,4",
        row = 3,
        col = 4,
        status = "free_target",
        value = 430,
        earlyStrategicValue = 430,
        progress = 3,
        reachable = true,
        earlyPrimaryTarget = false
    }
    local rear = {
        key = "1,4",
        row = 1,
        col = 4,
        status = "free_target",
        value = 390,
        earlyStrategicValue = 390,
        progress = 0,
        reachable = true,
        earlyPrimaryTarget = false
    }
    local held = {
        key = "3,5",
        row = 3,
        col = 5,
        status = "owned_uncovered",
        value = 410,
        earlyStrategicValue = 410,
        progress = 3,
        occupiedByUs = true
    }

    local meta = frontier.apply({primary, support, rear, held}, {primary}, ctx)

    assertEquals(meta.primary, 1, "selected primary should become frontier target")
    assertEquals(meta.support, 1, "near-behind free cell should become support")
    assertEquals(meta.rear, 1, "deep-behind free cell should become rear support")
    assertEquals(meta.hold, 1, "owned cell near the frontier should become frontier hold")
    assertEquals(primary.earlyFrontierRole, "frontier_target")
    assertEquals(support.earlyFrontierRole, "support_cover")
    assertEquals(rear.earlyFrontierRole, "rear_support")
    assertEquals(held.earlyFrontierRole, "frontier_hold")
    assertEquals(policy.cellValue(support), 340, "support cell target value should be lowered")
    assertEquals(policy.cellValue(rear), 230, "rear cell target value should be lowered more")
    assertEquals(policy.coverUrgencyBonus(support, ctx), 150, "support cell should carry cover value")
    assertEquals(policy.coverUrgencyBonus(held, ctx), 120, "frontier hold should ask for cover")
end)

runTest("early_position_frontier_floor_demotes_behind_targets_before_spacing", function()
    local map = require("ai_tournament.early_position_map")
    local frontier = require("ai_tournament.early_position_frontier")
    local policy = require("ai_tournament.early_position_cell_policy")
    local private = map._private
    local ctx = {
        cfg = {
            EARLY_POSITION_FRONTIER_ENABLED = true,
            EARLY_POSITION_FRONTIER_PRE_TARGET_ENABLED = true,
            EARLY_POSITION_FRONTIER_FLOOR_MARGIN = 1,
            EARLY_POSITION_FRONTIER_SUPPORT_RADIUS = 2,
            EARLY_POSITION_FRONTIER_SUPPORT_TARGET_PENALTY = 90,
            EARLY_POSITION_FRONTIER_REAR_TARGET_PENALTY = 160
        }
    }
    local cells = {
        {
            key = "3,5",
            row = 3,
            col = 5,
            status = "owned_uncovered",
            value = 250,
            earlyStrategicValue = 250,
            progress = 3,
            occupiedByUs = true
        },
        {
            key = "1,5",
            row = 1,
            col = 5,
            status = "free_target",
            value = 900,
            earlyStrategicValue = 900,
            progress = 1,
            reachable = true
        },
        {
            key = "4,5",
            row = 4,
            col = 5,
            status = "next_expansion",
            value = 520,
            earlyStrategicValue = 520,
            progress = 4,
            reachable = true
        }
    }

    local meta = frontier.preselect(cells, ctx)
    private.sortCellsByValue(cells)
    local selected = private.spacedTopCells(cells, 3, private.reachablePrimaryTarget, 2)
    local behind = nil
    for _, cell in ipairs(cells) do
        if cell.key == "1,5" then
            behind = cell
            break
        end
    end

    assertEquals(meta.suppressed, 1, "behind target should be demoted before primary selection")
    assertEquals(selected[1].key, "4,5", "behind cell must not be selected as primary target")
    assertEquals(behind.earlyFrontierPreTargetSuppressed, true, "behind cell should keep floor diagnostic")
    assertEquals(behind.earlyPrimaryTarget, false, "behind cell should not generate primary occupation")
    assertEquals(policy.rejectReason(behind, ctx), "frontier_floor", "reject reason should identify frontier floor")
    assertTrue(
        policy.isGoodStrategicCell(behind, ctx, {ignorePrimaryTarget = true}),
        "behind cell can still be reused as support when explicitly requested"
    )
end)

runTest("early_position_projected_frontier_prefers_advanced_sparse_anchor", function()
    local map = require("ai_tournament.early_position_map")
    local frontier = require("ai_tournament.early_position_frontier")
    local policy = require("ai_tournament.early_position_cell_policy")
    local private = map._private
    local ctx = {
        cfg = {
            EARLY_POSITION_FRONTIER_ENABLED = true,
            EARLY_POSITION_FRONTIER_PRE_TARGET_ENABLED = true,
            EARLY_POSITION_FRONTIER_PROJECTED_ENABLED = true,
            EARLY_POSITION_FRONTIER_PROJECTED_TARGET_BONUS = 80,
            EARLY_POSITION_FRONTIER_PROJECTED_PROGRESS_WEIGHT = 100,
            EARLY_POSITION_FRONTIER_PROJECTED_ROUTE_WEIGHT = 70,
            EARLY_POSITION_FRONTIER_PROJECTED_VALUE_WEIGHT = 0.08,
            EARLY_POSITION_FRONTIER_SUPPORT_RADIUS = 2,
            EARLY_POSITION_FRONTIER_SUPPORT_TARGET_PENALTY = 90,
            EARLY_POSITION_TARGET_MIN_DISTANCE = 2,
            EARLY_POSITION_MAP_TOP_N = 4
        }
    }
    local advanced = {
        key = "4,4",
        row = 4,
        col = 4,
        status = "free_target",
        value = 500,
        earlyStrategicValue = 500,
        progress = 4,
        routeProximity = 1.0,
        reachable = true,
        goodEarlyStrategic = true
    }
    local adjacentBehind = {
        key = "4,3",
        row = 4,
        col = 3,
        status = "free_target",
        value = 900,
        earlyStrategicValue = 900,
        progress = 3,
        routeProximity = 0.9,
        reachable = true,
        goodEarlyStrategic = true
    }
    local lateral = {
        key = "6,6",
        row = 6,
        col = 6,
        status = "next_expansion",
        value = 450,
        earlyStrategicValue = 450,
        progress = 3,
        routeProximity = 0.2,
        lateralExpansionValue = 150,
        reachable = true,
        goodEarlyStrategic = true
    }
    local cells = {adjacentBehind, advanced, lateral}

    local meta = frontier.preselect(cells, ctx)
    private.sortCellsByValue(cells)
    local selected = private.spacedTopCells(cells, 4, private.reachablePrimaryTarget, 2)

    assertEquals(meta.projected.anchors, 2, "advanced and lateral cells should both become sparse anchors")
    assertEquals(meta.projected.suppressed, 1, "adjacent behind cell should become support before spacing")
    assertEquals(advanced.earlyProjectedFrontierAnchor, true, "advanced route cell should be a projected anchor")
    assertEquals(lateral.earlyProjectedFrontierAnchor, true, "wide cell should stay available as a lateral anchor")
    assertEquals(adjacentBehind.earlyFrontierRole, "support_cover", "adjacent lower-progress cell should become cover")
    assertEquals(
        policy.rejectReason(adjacentBehind, ctx),
        "frontier_projected_support",
        "reject reason should explain projected frontier support"
    )
    assertEquals(selected[1].key, "4,4", "advanced anchor should beat the local high-value support cell")
    assertEquals(selected[2].key, "6,6", "lateral anchor should keep width instead of collapsing to one lane")
end)

runTest("early_position_frontier_floor_is_local_by_lane", function()
    local frontier = require("ai_tournament.early_position_frontier")
    local policy = require("ai_tournament.early_position_cell_policy")
    local ctx = {
        cfg = {
            EARLY_POSITION_FRONTIER_ENABLED = true,
            EARLY_POSITION_FRONTIER_PRE_TARGET_ENABLED = true,
            EARLY_POSITION_FRONTIER_PROJECTED_ENABLED = false,
            EARLY_POSITION_FRONTIER_FLOOR_MARGIN = 1,
            EARLY_POSITION_FRONTIER_LOCAL_LATERAL_MARGIN = 0.75,
            EARLY_POSITION_FRONTIER_SUPPORT_RADIUS = 2,
            EARLY_POSITION_FRONTIER_REAR_TARGET_PENALTY = 160
        }
    }
    local cells = {
        {
            key = "4,4",
            row = 4,
            col = 4,
            status = "owned_uncovered",
            value = 400,
            earlyStrategicValue = 400,
            progress = 4,
            lateral = 0.0,
            occupiedByUs = true
        },
        {
            key = "1,4",
            row = 1,
            col = 4,
            status = "free_target",
            value = 800,
            earlyStrategicValue = 800,
            progress = 1,
            lateral = 0.1,
            reachable = true
        },
        {
            key = "1,7",
            row = 1,
            col = 7,
            status = "free_target",
            value = 500,
            earlyStrategicValue = 500,
            progress = 1,
            lateral = 2.2,
            reachable = true
        }
    }

    local meta = frontier.preselect(cells, ctx)

    assertEquals(meta.suppressed, 1, "same-lane rear cell should be demoted")
    assertEquals(cells[2].earlyFrontierRole, "rear_support", "same-lane rear cell should become rear support")
    assertEquals(policy.rejectReason(cells[2], ctx), "frontier_floor")
    assertEquals(cells[3].earlyFrontierPreTargetSuppressed, nil, "wide lateral cell should remain target-capable")
end)

runTest("early_position_home_adjacent_cells_are_reserve_without_defend_now", function()
    local map = require("ai_tournament.early_position_map")
    local private = map._private
    local route = {
        ownHub = {row = 1, col = 2}
    }
    local ctx = {
        cfg = {
            EARLY_POSITION_HOME_ADJACENT_RESERVE_ENABLED = true,
            EARLY_POSITION_HOME_ADJACENT_RESERVE_PENALTY = 160,
            EARLY_POSITION_HOME_ADJACENT_OCCUPIED_EXTRA_PENALTY = 100
        },
        activeContracts = {
            defenseActive = false,
            activeNames = {"BUILD_POSITION"}
        }
    }
    local adjacent = {row = 2, col = 2}
    local distant = {row = 3, col = 3}

    assertEquals(
        private.homeAdjacentReservePenalty(ctx, route, adjacent, false),
        -160,
        "free home-adjacent cells should be soft-reserved"
    )
    assertEquals(
        private.homeAdjacentReservePenalty(ctx, route, adjacent, true),
        -260,
        "occupied home-adjacent cells should be easier to release"
    )
    assertEquals(
        private.homeAdjacentReservePenalty(ctx, route, distant, true),
        0,
        "non-adjacent cells should not receive home reserve penalty"
    )
end)

runTest("early_position_home_adjacent_reserve_turns_off_during_defend_now", function()
    local map = require("ai_tournament.early_position_map")
    local private = map._private
    local route = {
        ownHub = {row = 1, col = 2}
    }
    local ctx = {
        cfg = {
            EARLY_POSITION_HOME_ADJACENT_RESERVE_ENABLED = true,
            EARLY_POSITION_HOME_ADJACENT_RESERVE_PENALTY = 160,
            EARLY_POSITION_HOME_ADJACENT_OCCUPIED_EXTRA_PENALTY = 100
        },
        activeContracts = {
            defenseActive = true,
            activeNames = {"DEFEND_NOW", "BUILD_POSITION"}
        }
    }

    assertEquals(
        private.homeAdjacentReservePenalty(ctx, route, {row = 2, col = 2}, true),
        0,
        "DEFEND_NOW should be allowed to use commandant-adjacent cells"
    )
end)

for _, result in ipairs(results) do
    local status = result.ok and "PASS" or "FAIL"
    print(string.format("[%s] %s (%.2f ms)", status, result.name, result.ms))
    if not result.ok then
        print(result.err)
    end
end

local failures = 0
for _, result in ipairs(results) do
    if not result.ok then
        failures = failures + 1
    end
end

if failures > 0 then
    os.exit(1)
end
