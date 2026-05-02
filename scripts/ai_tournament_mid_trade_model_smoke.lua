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

local function unit(name, player, row, col, overrides)
    local hp = ({
        Commandant = 12,
        Wingstalker = 3,
        Crusher = 4,
        Bastion = 6,
        Cloudstriker = 4,
        Earthstalker = 3,
        Healer = 4,
        Artillery = 5,
        Rock = 5
    })[name] or 3
    local out = {
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = hp,
        startingHp = hp,
        move = 0,
        atkRange = 1,
        atkDamage = 2,
        hasActed = false,
        hasMoved = false,
        actionsUsed = 0
    }
    for key, value in pairs(overrides or {}) do
        out[key] = value
    end
    return out
end

local function stateWith(units)
    return {
        currentPlayer = 1,
        currentTurn = 11,
        turnNumber = 11,
        gridSize = 8,
        units = units or {},
        neutralBuildings = {},
        commandHubs = {
            [1] = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
            [2] = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12}
        },
        supply = {
            [1] = {},
            [2] = {}
        }
    }
end

local function getUnitAt(state, row, col)
    for _, item in ipairs(state.units or {}) do
        if item.row == row and item.col == col then
            return item
        end
    end
    for playerId, hub in pairs(state.commandHubs or {}) do
        if hub.row == row and hub.col == col then
            return {
                name = hub.name or "Commandant",
                player = playerId,
                row = hub.row,
                col = hub.col,
                currentHp = hub.currentHp,
                startingHp = hub.startingHp
            }
        end
    end
    return nil
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

local function removeUnitAt(state, row, col)
    for index = #((state and state.units) or {}), 1, -1 do
        local item = state.units[index]
        if item and item.row == row and item.col == col then
            table.remove(state.units, index)
            return
        end
    end
end

local function applyAction(ai, state, action)
    if not (state and action and action.type and action.type ~= "skip") then
        return
    end
    local actor = action.unit and getUnitAt(state, action.unit.row, action.unit.col) or nil
    if action.type == "move" and actor and action.target then
        actor.row = action.target.row
        actor.col = action.target.col
        actor.hasMoved = true
        actor.actionsUsed = (actor.actionsUsed or 0) + 1
    elseif action.type == "attack" and actor and action.target then
        local target = getUnitAt(state, action.target.row, action.target.col)
        if target then
            local damage = ai:calculateDamage(actor, target)
            target.currentHp = math.max(0, (target.currentHp or target.startingHp or 0) - damage)
            actor.hasActed = true
            actor.actionsUsed = (actor.actionsUsed or 0) + 1
            if target.currentHp <= 0 and target.player ~= nil and target.player > 0 and target.name ~= "Commandant" then
                removeUnitAt(state, action.target.row, action.target.col)
            end
        end
    end
end

local function simulate(ai, state, actions)
    local nextState = clone(state)
    for _, action in ipairs(actions or {}) do
        applyAction(ai, nextState, action)
    end
    return nextState
end

local function mkAI(reference)
    local values = {
        Commandant = 150,
        Artillery = 90,
        Crusher = 80,
        Earthstalker = 75,
        Cloudstriker = 75,
        Bastion = 70,
        Wingstalker = 45,
        Healer = 40
    }
    return {
        aiReference = reference,
        getOpponentPlayer = function(_, playerId)
            return playerId == 1 and 2 or 1
        end,
        isHubUnit = function(_, item)
            return item and item.name == "Commandant"
        end,
        isObstacleUnit = function(_, item)
            return item and (item.player == 0 or item.name == "Rock")
        end,
        getUnitAtPosition = function(_, state, row, col)
            return getUnitAt(state, row, col)
        end,
        calculateDamage = function(_, attacker)
            return attacker and attacker.atkDamage or 0
        end,
        getUnitBaseValue = function(_, item)
            return item and values[item.name] or 25
        end
    }
end

local function ctx(reference)
    return {
        aiPlayer = 1,
        enemyPlayer = 2,
        aiReference = reference,
        phase = {name = "mid", mid = true, early = false},
        cfg = {},
        stats = {},
        cache = {
            simulate = simulate
        }
    }
end

runTest("mid_trade_accepts_clean_high_value_damage", function()
    local trade = require("ai_tournament.mid_trade_model")
    local ai = mkAI("maggie")
    local state = stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 3}),
        unit("Bastion", 2, 4, 4, {atkRange = 1, atkDamage = 2, move = 0})
    })
    local context = ctx("maggie")
    local result = trade.evaluateAttack(ai, state, context, {
        type = "attack",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 4}
    })

    assertTrue(result.accepted == true, "clean high-value damage should be acceptable in mid")
    assertTrue(result.totalDamage == 3, "expected attack damage to be read")
    assertTrue(result.enemyReply == nil, "target should not have a reply from range")
    assertEquals(context.stats.midTradeAccepted, 1, "stats should count accepted trades")
end)

runTest("mid_trade_personality_changes_weak_trade_acceptance", function()
    local trade = require("ai_tournament.mid_trade_model")
    local state = stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 4}),
        unit("Artillery", 2, 4, 4, {atkRange = 3, atkDamage = 2, move = 0})
    })
    local action = {
        type = "attack",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 4}
    }

    local burt = trade.evaluateAttack(mkAI("burt"), state, ctx("burt"), action)
    local marge = trade.evaluateAttack(mkAI("marge"), state, ctx("marge"), action)

    assertTrue(burt.accepted == true, "Burt should accept a pressure trade with light exposure")
    assertTrue(marge.accepted == true, "Marge should keep the same legal damage trade in the ranking")
    assertTrue(marge.legalDamageCandidate == true, "Marge should mark the low-margin trade as scored but low value")
    assertEquals(marge.originalRejectReason, "mid_trade_below_material_threshold")
    assertTrue(burt.materialDelta < marge.thresholds.minMaterialDelta, "the gap should be the personality threshold")
end)

runTest("mid_trade_can_still_disable_legal_damage_softening", function()
    local trade = require("ai_tournament.mid_trade_model")
    local state = stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 4}),
        unit("Artillery", 2, 4, 4, {atkRange = 3, atkDamage = 2, move = 0})
    })
    local action = {
        type = "attack",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 4}
    }
    local context = ctx("marge")
    context.cfg.PIPELINE_V2_MID_KEEP_LEGAL_DAMAGE_ATTACKS = false

    local result = trade.evaluateAttack(mkAI("marge"), state, context, action)

    assertTrue(result.accepted == false, "flag should restore strict threshold rejection")
    assertEquals(result.reason, "mid_trade_below_material_threshold")
end)

runTest("endgame_trade_relaxes_value_thresholds_for_real_damage", function()
    local trade = require("ai_tournament.mid_trade_model")
    local state = stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 4}),
        unit("Artillery", 2, 4, 4, {atkRange = 3, atkDamage = 2, move = 0})
    })
    local action = {
        type = "attack",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 4}
    }

    local midContext = ctx("marge")
    local endContext = ctx("marge")
    endContext.phase = {name = "endgame", endgame = true, mid = false, early = false}
    endContext.pipelineV2EndRuntime = true

    local midResult = trade.evaluateAttack(mkAI("marge"), state, midContext, action)
    local endResult = trade.evaluateAttack(mkAI("marge"), state, endContext, action)

    assertTrue(midResult.accepted == true, "mid should keep this legal low-value trade as a scored candidate")
    assertTrue(midResult.legalDamageCandidate == true, "mid should mark threshold-relaxed legal damage explicitly")
    assertTrue(endResult.accepted == true, "endgame should keep real faction damage as a candidate")
    assertTrue(endResult.legalDamageCandidate ~= true, "endgame should accept through relaxed thresholds, not the low-value shim")
    assertTrue(endResult.thresholds.endgameRelaxed == true, "endgame threshold relaxation should be explicit")
    assertTrue(endResult.totalDamage > 0 and endResult.factionAttackCount > 0, "endgame relaxation still requires real enemy damage")
end)

runTest("endgame_material_advantage_rewards_suicide_kill_without_veto", function()
    local trade = require("ai_tournament.mid_trade_model")
    local ai = mkAI("burns")
    local action = {
        type = "attack",
        unit = {row = 4, col = 3},
        target = {row = 4, col = 4}
    }
    local advantageState = stateWith({
        unit("Crusher", 1, 4, 3, {atkDamage = 3, currentHp = 4, startingHp = 4}),
        unit("Wingstalker", 1, 2, 2),
        unit("Healer", 1, 2, 3),
        unit("Earthstalker", 2, 4, 4, {currentHp = 3, startingHp = 3}),
        unit("Artillery", 2, 4, 6, {atkRange = 3, atkDamage = 5, move = 0})
    })
    local evenState = stateWith({
        unit("Crusher", 1, 4, 3, {atkDamage = 3, currentHp = 4, startingHp = 4}),
        unit("Earthstalker", 2, 4, 4, {currentHp = 3, startingHp = 3}),
        unit("Artillery", 2, 4, 6, {atkRange = 3, atkDamage = 5, move = 0})
    })
    local advantageCtx = ctx("burns")
    advantageCtx.phase = {name = "endgame", endgame = true, mid = false, early = false, supply = {[1] = 0, [2] = 0}}
    advantageCtx.pipelineV2EndRuntime = true
    advantageCtx.cfg.PIPELINE_V2_ENDGAME_SUICIDE_KILL_MATERIAL_ADVANTAGE_BONUS = 3000
    advantageCtx.cfg.PIPELINE_V2_ENDGAME_SUICIDE_KILL_MATERIAL_ADVANTAGE_PER_UNIT = 500
    local evenCtx = ctx("burns")
    evenCtx.phase = advantageCtx.phase
    evenCtx.pipelineV2EndRuntime = true
    evenCtx.cfg = advantageCtx.cfg

    local advantage = trade.evaluateAttack(ai, advantageState, advantageCtx, action)
    local even = trade.evaluateAttack(ai, evenState, evenCtx, action)

    assertTrue(advantage.accepted == true, "endgame should keep the suicidal kill as a legal scored candidate")
    assertTrue(advantage.kills > 0, "fixture should kill a unit")
    assertTrue(advantage.enemyReplyLethal == true, "fixture should expose the attacker to lethal reply")
    assertTrue(advantage.endgameSuicideKillAccepted == true, "material advantage suicide kill should be tagged")
    assertTrue((advantage.endgameAvailableUnits and advantage.endgameAvailableUnits.advantage or 0) > 0, "available unit advantage should be measured")
    assertTrue(even.endgameSuicideKillAccepted ~= true, "no unit advantage should not get the suicide-kill bonus")
    assertTrue(advantage.score > even.score, "material advantage should lift the suicidal kill score")
end)

runTest("mid_trade_tags_suicide_chip_without_vetoing_it", function()
    local trade = require("ai_tournament.mid_trade_model")
    local ai = mkAI("burt")
    local state = stateWith({
        unit("Crusher", 1, 4, 3, {atkDamage = 1, currentHp = 4, startingHp = 4}),
        unit("Earthstalker", 2, 4, 4, {currentHp = 3, startingHp = 3}),
        unit("Artillery", 2, 4, 6, {atkRange = 3, atkDamage = 5, move = 0})
    })
    local context = ctx("burt")
    local result = trade.evaluateAttack(ai, state, context, {
        type = "attack",
        unit = {row = 4, col = 3},
        target = {row = 4, col = 4}
    })

    assertTrue(result.accepted == true, "suicide chip remains a legal scored candidate")
    assertTrue(result.legalDamageCandidate == true, "unsafe chip should be softened, not promoted to a good trade")
    assertTrue(result.enemyReplyLethal == true, "fixture should expose the attacker to lethal reply")
    assertTrue(result.drawSuicideChip == true, "low-value suicidal chip should be tagged")
    assertTrue(result.drawSuicideSetup ~= true, "chip should not be confused with a setup")
end)

runTest("mid_trade_does_not_tag_one_hp_suicide_setup_as_chip", function()
    local trade = require("ai_tournament.mid_trade_model")
    local ai = mkAI("burt")
    local state = stateWith({
        unit("Crusher", 1, 4, 3, {atkDamage = 2, currentHp = 4, startingHp = 4}),
        unit("Earthstalker", 2, 4, 4, {currentHp = 3, startingHp = 3}),
        unit("Artillery", 2, 4, 6, {atkRange = 3, atkDamage = 5, move = 0})
    })
    local context = ctx("burt")
    context.cfg.PIPELINE_V2_MID_DRAW_SUICIDE_SETUP_REMAINING_HP = 1
    local result = trade.evaluateAttack(ai, state, context, {
        type = "attack",
        unit = {row = 4, col = 3},
        target = {row = 4, col = 4}
    })

    assertTrue(result.accepted == true, "suicide setup remains legal")
    assertTrue(result.enemyReplyLethal == true, "fixture should still be suicidal")
    assertTrue(result.drawSuicideChip ~= true, "leaving a one-hp follow-up should not be low-value chip")
    assertTrue(result.drawSuicideSetup == true, "setup tag should explain why it avoided chip penalty")
end)

runTest("mid_trade_rejects_zero_damage_faction_attack", function()
    local trade = require("ai_tournament.mid_trade_model")
    local ai = mkAI("base")
    local state = stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 0}),
        unit("Bastion", 2, 4, 4, {atkRange = 1, atkDamage = 2, move = 0})
    })
    local result = trade.evaluateAttack(ai, state, ctx("base"), {
        type = "attack",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 4}
    })

    assertTrue(result.accepted == false, "zero damage should never be a useful mid trade")
    assertEquals(result.reason, "mid_trade_zero_damage", "zero damage reason should be explicit")
end)

runTest("mid_trade_keeps_zero_damage_faction_attack_only_as_draw_reset", function()
    local trade = require("ai_tournament.mid_trade_model")
    local ai = mkAI("base")
    local state = stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 0}),
        unit("Bastion", 2, 4, 4, {atkRange = 1, atkDamage = 2, move = 0})
    })
    state.turnsWithoutDamage = 3
    local context = ctx("base")
    local result = trade.evaluateAttack(ai, state, context, {
        type = "attack",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 4}
    })

    assertTrue(result.accepted == true, "near draw limit, a faction attack can be kept as official reset")
    assertEquals(result.reason, "mid_trade_draw_reset_zero_damage", "draw reset reason should be explicit")
    assertTrue(result.drawZeroDamageReset == true, "zero-damage reset should be tagged")
    assertTrue(result.totalDamage == 0, "fixture must remain zero damage")

    local strictContext = ctx("base")
    strictContext.cfg.PIPELINE_V2_MID_KEEP_DRAW_RESET_ZERO_DAMAGE_ATTACKS = false
    strictContext.stats = {}
    local strict = trade.evaluateAttack(ai, state, strictContext, {
        type = "attack",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 4}
    })
    assertTrue(strict.accepted == false, "flag should restore strict zero-damage rejection")
    assertEquals(strict.reason, "mid_trade_zero_damage")
end)

runTest("mid_trade_uses_action_target_snapshot_when_lookup_misses", function()
    local trade = require("ai_tournament.mid_trade_model")
    local ai = mkAI("burt")
    local state = stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 3})
    })
    local result = trade.evaluateAttack(ai, state, ctx("burt"), {
        type = "attack",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 4},
        targetUnit = unit("Bastion", 2, 4, 4, {atkRange = 1, atkDamage = 2, move = 0})
    })

    assertTrue(result.accepted == true, "target snapshot should preserve faction attack semantics")
    assertEquals(result.factionAttackCount, 1, "snapshot target should count as enemy faction")
    assertEquals(result.totalDamage, 3, "snapshot target should receive normal damage accounting")
end)

runTest("mid_trade_accepts_commandant_lethal_as_win_now", function()
    local trade = require("ai_tournament.mid_trade_model")
    local ai = mkAI("marge")
    local state = stateWith({
        unit("Artillery", 1, 4, 5, {atkRange = 3, atkDamage = 12})
    })
    state.commandHubs[2] = {
        name = "Commandant",
        player = 2,
        row = 4,
        col = 8,
        currentHp = 10,
        startingHp = 12
    }
    local result = trade.evaluateAttack(ai, state, ctx("marge"), {
        type = "attack",
        unit = {row = 4, col = 5},
        target = {row = 4, col = 8}
    })

    assertTrue(result.accepted == true, "commandant lethal should always be accepted")
    assertEquals(result.reason, "mid_trade_win_now", "win-now reason should be explicit")
    assertTrue(result.commandantLethal == true, "result should expose commandant lethal")
end)

runTest("mid_trade_requires_context_cache_simulation", function()
    local trade = require("ai_tournament.mid_trade_model")
    local ai = mkAI("maggie")
    ai.simulateActionSequenceForPlayer = function()
        error("mid trade should not bypass ctx.cache.simulate", 2)
    end
    local state = stateWith({
        unit("Artillery", 1, 4, 1, {atkRange = 3, atkDamage = 3}),
        unit("Bastion", 2, 4, 4, {atkRange = 1, atkDamage = 2, move = 0})
    })
    local context = ctx("maggie")
    context.cache = nil

    local result = trade.evaluateAttack(ai, state, context, {
        type = "attack",
        unit = {row = 4, col = 1},
        target = {row = 4, col = 4}
    })

    assertTrue(result.accepted == false, "trade should reject without context simulation")
    assertEquals(result.reason, "mid_trade_simulation_unavailable", "missing cache should be explicit")
    assertEquals(context.stats.midTradeRejected, 1, "stats should count the rejected trade")
end)

local failed = 0
for _, result in ipairs(results) do
    if result.ok then
        print(string.format("[PASS] %s (%.2f ms)", result.name, result.ms))
    else
        failed = failed + 1
        print(string.format("[FAIL] %s (%.2f ms)", result.name, result.ms))
        print(result.err)
    end
end

if failed > 0 then
    print(string.format("ai_tournament_mid_trade_model_smoke failed: %d/%d", failed, #results))
    os.exit(1)
end

print(string.format("ai_tournament_mid_trade_model_smoke passed: %d/%d", #results, #results))
