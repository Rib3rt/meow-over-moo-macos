package.path = package.path .. ";./?.lua"

local retroGenerator = require("scenario_tooling.retro_generator")
local qualityEvaluator = require("scenario_tooling.quality_evaluator")
local solver = require("scenario_tooling.solver")
local stateEngine = require("scenario_tooling.state_engine")

local results = {}

local function runTest(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = { name = name, ok = ok, err = err }
end

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message or "assertEquals failed", tostring(expected), tostring(actual)), 2)
    end
end

local function hasMicro(dossier, microId)
    for _, micro in ipairs(dossier.microInteractions or {}) do
        if tostring(micro.id or micro.microId or "") == tostring(microId) then
            return true
        end
    end
    return false
end

local function hasRoleSignaturePart(dossier, part)
    local roleSignature = dossier.tacticalFingerprint and dossier.tacticalFingerprint.role_signature or ""
    return type(roleSignature) == "string" and roleSignature:find(part, 1, true) ~= nil
end

local function hasReason(result, code)
    for _, reason in ipairs(result.reasons or {}) do
        if tostring(reason.code or "") == tostring(code) then
            return true
        end
    end
    for _, reason in ipairs(result.unknowns or {}) do
        if tostring(reason.code or "") == tostring(code) then
            return true
        end
    end
    return false
end

local function getPredicateEvidence(dossier, predicateName)
    for _, result in ipairs(dossier.predicateResults or {}) do
        if result.predicate == predicateName or result.name == predicateName then
            return result.evidence and result.evidence.evidence
        end
    end
    return nil
end

local function findUnit(state, id)
    for _, unit in ipairs(state and state.units or {}) do
        if unit.id == id then
            return unit
        end
    end
    return nil
end

local function assertUnit(state, id, name, row, col, currentHp, startingHp)
    local unit = findUnit(state, id)
    assertTrue(type(unit) == "table", id .. " missing")
    assertEquals(unit.name, name, id .. " unit type")
    assertEquals(tonumber(unit.row), row, id .. " row")
    assertEquals(tonumber(unit.col), col, id .. " col")
    assertEquals(tonumber(unit.currentHp), currentHp, id .. " currentHp")
    assertEquals(tonumber(unit.startingHp), startingHp, id .. " startingHp")
end

local function assertActionCell(action, row, col, label)
    assertTrue(type(action) == "table" and type(action.to) == "table", label .. " destination missing")
    assertEquals(tonumber(action.to.row), row, label .. " row")
    assertEquals(tonumber(action.to.col), col, label .. " col")
end

local function actionSignature(action)
    if type(action) ~= "table" then
        return ""
    end
    local actor = tostring(action.actorId or "")
    local target = tostring(action.targetId or "")
    if action.type == "move" then
        local to = action.to or {}
        return string.format("move:%s@%s,%s", actor, tostring(to.row or ""), tostring(to.col or ""))
    end
    if action.type == "attack" then
        return string.format("attack:%s>%s", actor, target)
    end
    return tostring(action.type or "")
end

local function tableHasAnyKey(tbl, keys)
    if type(tbl) ~= "table" then
        return false
    end
    for i = 1, #keys do
        if tbl[keys[i]] ~= nil then
            return true
        end
    end
    return false
end

local function consequenceMicroId(entry)
    if type(entry) ~= "table" then
        return ""
    end
    return tostring(
        entry.microInteractionId
        or entry.microInteraction
        or entry.micro_id
        or entry.micro
        or entry.id
        or ""
    )
end

local function consequenceStatusProven(entry)
    if type(entry) ~= "table" then
        return false
    end
    if entry.proven == true then
        return true
    end
    if entry.status == true then
        return true
    end
    if type(entry.status) == "string" then
        local lowered = string.lower(entry.status)
        return lowered == "proven" or lowered == "true" or lowered == "verified"
    end
    return false
end

local function consequenceHasChangedField(entry)
    if type(entry) ~= "table" then
        return false
    end
    if tableHasAnyKey(entry, { "winning_line", "red_response", "false_line", "exactness", "outcome" }) then
        return true
    end
    local changed = entry.changed or entry.change or entry.delta or entry.effect
    if type(changed) == "table" then
        return tableHasAnyKey(changed, { "winning_line", "red_response", "false_line", "exactness", "outcome" })
    end
    return false
end

local function consequenceMatchesAction(entry, actionIndex, action)
    if type(entry) ~= "table" or type(action) ~= "table" then
        return false
    end
    local idx = tonumber(entry.actionIndex or entry.action_index or entry.index)
    if idx ~= nil and idx == actionIndex then
        return true
    end
    local sig = tostring(entry.actionSignature or entry.action_signature or "")
    if sig == "" then
        return false
    end
    local canonical = actionSignature(action)
    if sig == canonical then
        return true
    end
    local actor = tostring(action.actorId or "")
    local actionType = tostring(action.type or "")
    return sig:find(actor, 1, true) ~= nil and sig:find(actionType, 1, true) ~= nil
end

runTest("composite_support_pressure_crusher_contact_smoke", function()
    local opts = {
        seed = 410,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = "composite_support_pressure_crusher_contact",
        maxAttempts = 1
    }
    local dossier = retroGenerator.generate(opts)
    assertTrue(type(dossier) == "table", "dossier required")
    assertEquals(dossier.pipelineState, "certified", "pipeline state should be certified")
    assertEquals(stateEngine.stateHash(dossier.scenarioState), "c55d3d64", "baseline composite state hash should not drift")
    assertEquals(dossier.tacticalFingerprint.hash, "9860c24e", "baseline tactical fingerprint should not drift")
    assertUnit(dossier.scenarioState, "blue_a_support", "Earthstalker", 5, 5, 3, 3)
    assertUnit(dossier.scenarioState, "blue_finisher", "Crusher", 7, 4, 4, 4)
    assertUnit(dossier.scenarioState, "red_commandant", "Commandant", 2, 4, 4, 12)
    assertUnit(dossier.scenarioState, "red_contact_blocker", "Bastion", 3, 4, 3, 6)
    assertUnit(dossier.scenarioState, "red_support_threat", "Earthstalker", 5, 7, 3, 3)

    local quality = qualityEvaluator.evaluate(dossier)
    assertTrue(type(quality) == "table", "quality evaluation required")
    assertEquals(quality.status, "approved", "quality status should be approved")
    assertEquals(quality.features.hasCompositionalContract, true, "quality should require compositional contract evidence")
    assertTrue(
        (quality.features.provenActionConsequenceCount or 0) >= 4,
        "quality should count proven action consequence evidence"
    )

    assertEquals(dossier.finisher.unitType, "Crusher", "finisher must be Crusher")
    assertEquals(dossier.finisher.family, "melee", "finisher family must be melee")
    assertTrue(hasRoleSignaturePart(dossier, "composite"), "role_signature must include composite")
    assertTrue(hasRoleSignaturePart(dossier, "contact_breach"), "role_signature must include contact_breach")

    local evidence = getPredicateEvidence(dossier, "critical_blue_unit") or {}
    assertEquals(evidence.redPressureUnit, "red_support_threat", "pressure role must be a separate Red unit")
    assertEquals(evidence.contactBlockerUnit, "red_contact_blocker", "contact blocker role must be declared")
    assertTrue(evidence.redPressureUnit ~= evidence.contactBlockerUnit, "pressure and blocker must not be the same unit")
    assertEquals(evidence.contactBlockerAlsoPressure, false, "blocker must not also satisfy pressure")
    assertEquals(evidence.pressureCanBeAttackedAtStart, false, "pressure must not be free to remove on the opening setup move")

    assertTrue(hasMicro(dossier, "RED_ATTACKS_SUPPORT"), "must include RED_ATTACKS_SUPPORT")
    assertTrue(hasMicro(dossier, "SUPPORT_CELL_GAIN"), "must include SUPPORT_CELL_GAIN")
    assertTrue(hasMicro(dossier, "FINISHER_CELL_GAIN"), "must include FINISHER_CELL_GAIN")
    assertTrue(hasMicro(dossier, "WRONG_TARGET_TEMPO_LOSS"), "must include WRONG_TARGET_TEMPO_LOSS")
    assertTrue(hasMicro(dossier, "ORDER_DEPENDENCY"), "must include ORDER_DEPENDENCY")
    assertTrue(not hasMicro(dossier, "LOS_OPEN_RANGED"), "must not include LOS_OPEN_RANGED")
    assertTrue(not hasMicro(dossier, "ROCK_AS_LOCK"), "must not include ROCK_AS_LOCK")

    local line = dossier.solution and dossier.solution.actions or {}
    assertTrue(#line >= 8, "solution should include at least 8 actions")
    assertTrue(line[1] and line[1].type == "move", "first move should be positioning, not an obvious attack")
    local finalAttack = nil
    for i = 1, #line do
        local action = line[i]
        if action.type == "attack" and tostring(action.targetId or "") == "red_commandant" then
            finalAttack = action
        end
    end
    assertTrue(finalAttack ~= nil, "solution must include attack on red_commandant")
    assertEquals(finalAttack.actorId, "blue_finisher", "final red_commandant attack must be by blue_finisher")

    local compositeContract = dossier.compositionalContract
        or dossier.compositionalEvidence
        or dossier.compositeContract
        or dossier.compositeEvidence
        or evidence.compositionalContract
        or evidence.compositionalEvidence
        or evidence.compositeContract
        or evidence.compositeEvidence
    assertTrue(type(compositeContract) == "table", "composite dossier must expose compositional contract/evidence table")

    local consequences = compositeContract.actionConsequences
        or compositeContract.action_consequences
        or compositeContract.consequences
        or compositeContract.evidence
    assertTrue(type(consequences) == "table", "compositional contract must include action consequences")
    assertTrue(#consequences >= 4, "compositional contract must prove at least 4 key action consequences")

    local keyActions = {}
    for i = 1, #line do
        local action = line[i]
        if action.type == "move"
            and tostring(action.actorId or "") == "blue_a_support"
            and keyActions.supportSetupMove == nil then
            keyActions.supportSetupMove = { index = i, action = action }
        elseif action.type == "attack"
            and tostring(action.actorId or "") == "blue_a_support"
            and tostring(action.targetId or "") == "red_contact_blocker"
            and keyActions.supportBlockerClearAttack == nil then
            keyActions.supportBlockerClearAttack = { index = i, action = action }
        elseif action.type == "move"
            and tostring(action.actorId or "") == "blue_finisher"
            and keyActions.crusherStagingMove == nil then
            keyActions.crusherStagingMove = { index = i, action = action }
        elseif action.type == "move"
            and tostring(action.actorId or "") == "blue_finisher"
            and keyActions.crusherStagingMove ~= nil
            and i > keyActions.crusherStagingMove.index
            and keyActions.crusherContactMove == nil then
            keyActions.crusherContactMove = { index = i, action = action }
        elseif action.type == "attack"
            and tostring(action.actorId or "") == "blue_finisher"
            and tostring(action.targetId or "") == "red_commandant"
            and keyActions.crusherPayoffAttack == nil then
            keyActions.crusherPayoffAttack = { index = i, action = action }
        end
    end
    assertTrue(keyActions.supportSetupMove ~= nil, "expected support setup move in winning line")
    assertTrue(keyActions.supportBlockerClearAttack ~= nil, "expected support blocker-clear attack in winning line")
    assertTrue(keyActions.crusherStagingMove ~= nil, "expected Crusher staging move in winning line")
    assertTrue(
        keyActions.crusherContactMove ~= nil or keyActions.crusherPayoffAttack ~= nil,
        "expected Crusher contact move or final payoff attack in winning line"
    )
    if keyActions.supportSetupMove and keyActions.supportBlockerClearAttack then
        assertTrue(
            keyActions.supportSetupMove.index < keyActions.supportBlockerClearAttack.index,
            "support setup move should occur before support blocker-clear attack"
        )
        assertActionCell(keyActions.supportSetupMove.action, 3, 5, "support setup move")
    end
    if keyActions.crusherStagingMove and keyActions.crusherPayoffAttack then
        assertTrue(
            keyActions.crusherStagingMove.index < keyActions.crusherPayoffAttack.index,
            "Crusher staging move should occur before final payoff attack"
        )
        assertActionCell(keyActions.crusherStagingMove.action, 5, 4, "Crusher staging move")
    end
    if keyActions.crusherContactMove then
        assertActionCell(keyActions.crusherContactMove.action, 3, 4, "Crusher contact move")
    end

    for i = 1, #consequences do
        local entry = consequences[i]
        assertTrue(
            tableHasAnyKey(entry, { "actionIndex", "action_index", "index", "actionSignature", "action_signature" }),
            "each composite action consequence must include actionIndex or actionSignature"
        )
        assertTrue(consequenceMicroId(entry) ~= "", "each composite action consequence must include microInteraction id")
        assertTrue(consequenceStatusProven(entry), "each composite action consequence must be proven/verified true")
        assertTrue(
            consequenceHasChangedField(entry),
            "each composite action consequence must include winning_line/red_response/false_line/exactness/outcome change"
        )
    end

    local function assertConsequential(key, record)
        local matched = nil
        for _, consequence in ipairs(consequences) do
            if consequenceMatchesAction(consequence, record.index, record.action) then
                matched = consequence
                break
            end
        end
        assertTrue(matched ~= nil, key .. " must have explicit compositional consequence evidence")
        assertTrue(consequenceMicroId(matched) ~= "", key .. " consequence must include microInteraction id")
        assertTrue(consequenceStatusProven(matched), key .. " consequence must be proven/verified true")
        assertTrue(
            consequenceHasChangedField(matched),
            key .. " consequence must include changed winning_line/red_response/false_line/exactness/outcome field"
        )
    end

    assertConsequential("support setup move", keyActions.supportSetupMove)
    assertConsequential("support blocker clear attack", keyActions.supportBlockerClearAttack)
    assertConsequential("Crusher staging move", keyActions.crusherStagingMove)
    if keyActions.crusherContactMove then
        assertConsequential("Crusher contact move", keyActions.crusherContactMove)
    else
        assertConsequential("Crusher payoff attack", keyActions.crusherPayoffAttack)
    end

    local finalBlueTurnStart = nil
    local currentBlueTurnStart = nil
    local currentPlayer = 1
    local sawRedMoveOrAttackBeforeFinalBlueTurn = false
    for i = 1, #line do
        local action = line[i]
        if currentPlayer == 1 and currentBlueTurnStart == nil then
            currentBlueTurnStart = i
        end
        if action.type == "end_turn" then
            if currentPlayer == 1 then
                finalBlueTurnStart = currentBlueTurnStart
                currentBlueTurnStart = nil
                currentPlayer = 2
            else
                currentPlayer = 1
            end
        end
    end
    assertTrue(finalBlueTurnStart ~= nil, "final blue turn boundary should be discoverable")
    for i = 1, finalBlueTurnStart - 1 do
        local action = line[i]
        if (action.type == "move" or action.type == "attack") and type(action.actorId) == "string" and action.actorId:find("^red_", 1, false) then
            sawRedMoveOrAttackBeforeFinalBlueTurn = true
            break
        end
    end
    assertTrue(sawRedMoveOrAttackBeforeFinalBlueTurn, "red policy line should include Red move/attack before final Blue turn")

    local twoTurnState = {}
    for key, value in pairs(dossier.scenarioState or {}) do
        twoTurnState[key] = value
    end
    twoTurnState.turnLimit = 2
    twoTurnState.scenarioTurn = 1
    local redPassProof = solver.proveNoBlueWinEvenIfRedPasses(twoTurnState, { maxNodes = 9000 })
    assertEquals(redPassProof.status, "no_blue_win_even_with_red_pass", "two-turn red-pass proof status mismatch")
end)

runTest("composite_quality_rejects_missing_action_consequence_evidence", function()
    local dossier = retroGenerator.generate({
        seed = 410,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = "composite_support_pressure_crusher_contact",
        maxAttempts = 1
    })
    assertEquals(dossier.pipelineState, "certified", "control dossier should certify before mutation")

    dossier.compositionalContract = nil
    dossier.ablationResults = nil
    local quality = qualityEvaluator.evaluate(dossier)
    assertEquals(quality.status, "reject", "quality should reject composite dossier without action-consequence evidence")
    assertTrue(
        hasReason(quality, "missing_compositional_contract"),
        "quality rejection should name missing_compositional_contract"
    )
end)

runTest("retro_generator_has_no_standard_ai_dependency", function()
    local file = io.open("scenario_tooling/retro_generator.lua", "r")
    assertTrue(file ~= nil, "retro_generator.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('require("ai', 1, true) == nil, "retro generator must not require standard AI")
    assertTrue(content:find("require('ai", 1, true) == nil, "retro generator must not require standard AI")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "retro generator must not depend on AI tournament modules")
    assertTrue(content:find("gameRuler", 1, true) == nil, "retro generator must not depend on runtime game ruler")
    assertTrue(content:find("factionSelect", 1, true) == nil, "retro generator must not depend on runtime menus")
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
        print("[PASS] " .. result.name)
    else
        print("[FAIL] " .. result.name .. " -> " .. tostring(result.err))
    end
end

print(string.format("scenario_composite_generator_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
