local finisherLibrary = require("scenario_tooling.finisher_library")
local microLibrary = require("scenario_tooling.micro_interaction_library")
local stateEngine = require("scenario_tooling.state_engine")
local solver = require("scenario_tooling.solver")
local redPolicy = require("scenario_tooling.red_policy")
local scenarioValidator = require("scenario_tooling.scenario_contract_validator")
local schemaContract = require("scenario_tooling.schema_contract")
local predicateContract = require("scenario_tooling.predicate_contract")
local compositionComposer = require("scenario_tooling.composition_composer")
local compositionLayoutConstraints = require("scenario_tooling.composition_layout_constraints")

local M = {
    VERSION = "retro_generator_core.v1.step8",
    GENERATOR_ID = "step8_retro_generator_core_v1"
}

local BOARD_MIN = 1
local BOARD_MAX = 8
local BLUE = 1
local RED = 2
local NEUTRAL = 0
local DEFAULT_TURN_LIMIT = 3
local DEFAULT_SCENARIO_TURN = 1
local DEFAULT_PROOF_DOMAIN = "defensive"
local DEFAULT_BATCH_COUNT = 10
local DEFAULT_NOVELTY_THRESHOLD = 0.32
local DEFAULT_MAX_CERT_ATTEMPTS = 120
local DEFAULT_SOLVER_MAX_NODES = 7000
local CONTRACT_MAX_ACTIONS_PER_TURN = 2

local HP_BY_UNIT = {
    Commandant = 12,
    Cloudstriker = 4,
    Crusher = 4,
    Artillery = 5,
    Bastion = 6,
    Wingstalker = 3,
    Earthstalker = 3,
    Healer = 4,
    Rock = 5
}

local MACRO_FIELDS = {
    solutionOrder = true,
    turnSequence = true,
    winningLine = true,
    scriptedRedResponses = true
}

local function stableString(v)
    if v == nil then
        return ""
    end
    if type(v) == "number" then
        return string.format("%.12g", v)
    end
    return tostring(v)
end

local function hashText(text)
    local hash = 5381
    local i
    for i = 1, #text do
        hash = ((hash * 33) + string.byte(text, i)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function tableLength(tbl)
    if type(tbl) ~= "table" then
        return 0
    end
    local n = 0
    local _
    for _ in pairs(tbl) do
        n = n + 1
    end
    return n
end

local function shallowCopyArray(arr)
    local out = {}
    if type(arr) ~= "table" then
        return out
    end
    local i
    for i = 1, #arr do
        out[i] = arr[i]
    end
    return out
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
    local k, v
    for k, v in pairs(value) do
        out[deepCopy(k, seen)] = deepCopy(v, seen)
    end
    return out
end

local function normalizeSeed(seed)
    if type(seed) == "number" then
        local n = math.floor(seed)
        if n < 0 then
            n = -n
        end
        return n % 4294967296
    end
    if type(seed) == "string" and seed ~= "" then
        return tonumber(hashText(seed), 16)
    end
    return 1
end

local function makeRng(seed)
    local state = normalizeSeed(seed)
    if state == 0 then
        state = 2463534242
    end
    local function nextInt()
        state = ((1664525 * state) + 1013904223) % 4294967296
        return state
    end
    local function nextRange(low, high)
        if high <= low then
            return low
        end
        local span = (high - low) + 1
        return low + (nextInt() % span)
    end
    return {
        nextInt = nextInt,
        nextRange = nextRange
    }
end

local function shuffleInPlace(arr, rng)
    local i
    for i = #arr, 2, -1 do
        local j = rng.nextRange(1, i)
        arr[i], arr[j] = arr[j], arr[i]
    end
end

local function inBounds(row, col)
    return row >= BOARD_MIN and row <= BOARD_MAX and col >= BOARD_MIN and col <= BOARD_MAX
end

local function parseCell(text)
    if type(text) ~= "string" then
        return nil
    end
    local colLetter, rowText = string.match(string.upper(text), "^([A-H])([1-8])$")
    if not colLetter then
        return nil
    end
    local col = string.byte(colLetter) - string.byte("A") + 1
    local row = tonumber(rowText)
    return { row = row, col = col }
end

local function formatCell(row, col)
    if not inBounds(row, col) then
        return nil
    end
    return string.char(string.byte("A") + col - 1) .. tostring(row)
end

local function cellKey(row, col)
    return tostring(row) .. "," .. tostring(col)
end

local function unit(id, name, player, row, col, hp)
    local maxHp = HP_BY_UNIT[name] or hp or 1
    local currentHp = tonumber(hp) or maxHp
    if currentHp > maxHp then
        currentHp = maxHp
    end
    if currentHp < 1 then
        currentHp = 1
    end
    return {
        id = id,
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = currentHp,
        startingHp = maxHp,
        hasMoved = false,
        hasActed = false,
        actionsUsed = 0,
        turnActions = {}
    }
end

local function canonicalAction(action)
    if type(action) ~= "table" then
        return {}
    end
    local out = {
        type = action.type,
        actorId = action.actorId,
        targetId = action.targetId
    }
    if type(action.from) == "table" then
        out.from = { row = tonumber(action.from.row), col = tonumber(action.from.col) }
    end
    if type(action.to) == "table" then
        out.to = { row = tonumber(action.to.row), col = tonumber(action.to.col) }
    end
    if type(action.targetCell) == "table" then
        out.targetCell = { row = tonumber(action.targetCell.row), col = tonumber(action.targetCell.col) }
    end
    out.id = action.id
    return out
end

local function actionSignature(action)
    local a = type(action) == "table" and action or {}
    local to = type(a.to) == "table" and a.to or {}
    local from = type(a.from) == "table" and a.from or {}
    return table.concat({
        stableString(a.type),
        stableString(a.actorId),
        stableString(a.targetId),
        stableString(from.row),
        stableString(from.col),
        stableString(to.row),
        stableString(to.col)
    }, ":")
end

local function actionMatches(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if a.id and b.id and a.id == b.id then
        return true
    end
    if a.type ~= b.type or stableString(a.actorId) ~= stableString(b.actorId) then
        return false
    end
    if a.type == "move" then
        local at = a.to or {}
        local bt = b.to or {}
        return tonumber(at.row) == tonumber(bt.row) and tonumber(at.col) == tonumber(bt.col)
    end
    if a.type == "attack" then
        return stableString(a.targetId) == stableString(b.targetId)
    end
    return a.type == "end_turn"
end

local function findAction(actions, matcher)
    local i
    for i = 1, #(actions or {}) do
        if matcher(actions[i]) then
            return actions[i]
        end
    end
    return nil
end

local function hasMacroField(spec)
    if type(spec) ~= "table" then
        return false
    end
    local k
    for k in pairs(MACRO_FIELDS) do
        if spec[k] ~= nil then
            return true
        end
    end
    return false
end

local function normalizeTurnLimit(opts)
    local n = tonumber(opts and opts.turnLimit)
    if n == nil then
        return DEFAULT_TURN_LIMIT
    end
    return math.floor(n)
end

local function normalizeN(opts)
    local n = tonumber((opts and (opts.N or opts.n)) or 3)
    if n == nil then
        return 3
    end
    return math.floor(n)
end

local function normalizeProofDomain(opts)
    local domain = opts and opts.proofDomain or DEFAULT_PROOF_DOMAIN
    if domain ~= "all_legal" and domain ~= "defensive" then
        return DEFAULT_PROOF_DOMAIN
    end
    return domain
end

local function cloneCells(cells)
    local out = {}
    local i
    for i = 1, #(cells or {}) do
        local c = cells[i]
        out[#out + 1] = {
            row = tonumber(c and c.row),
            col = tonumber(c and c.col)
        }
    end
    return out
end

local function cloneIdList(ids)
    local out = {}
    local i
    for i = 1, #(ids or {}) do
        out[#out + 1] = stableString(ids[i])
    end
    return out
end

local function solverBudget(opts)
    local maxNodes = tonumber(opts and opts.solverMaxNodes) or DEFAULT_SOLVER_MAX_NODES
    if maxNodes <= 0 then
        maxNodes = DEFAULT_SOLVER_MAX_NODES
    end
    return math.floor(maxNodes)
end

local function buildSolverOptions(candidate, opts, proofDomain)
    local policyConfig = type(candidate and candidate.scenarioRedPolicy) == "table" and candidate.scenarioRedPolicy or {}
    return {
        seed = candidate and candidate.seed or (opts and opts.seed),
        proofDomain = proofDomain,
        preferredLine = candidate and candidate.expectedWinningPrefix or nil,
        maxNodes = solverBudget(opts),
        requiredCells = cloneCells(policyConfig.requiredCells),
        criticalBlueUnitIds = cloneIdList(policyConfig.criticalBlueUnitIds)
    }
end

local function allBoardCells()
    local out = {}
    local row, col
    for row = BOARD_MIN, BOARD_MAX do
        for col = BOARD_MIN, BOARD_MAX do
            out[#out + 1] = { row = row, col = col }
        end
    end
    return out
end

local function pickMechanismFamily(finisherFamily)
    if finisherFamily == "melee" then
        return "access_lock"
    end
    if finisherFamily == "ranged" then
        return "los_lock"
    end
    if finisherFamily == "artillery" then
        return "timing_lock"
    end
    return "interference_lock"
end

local function predicateEntry(name, value, evidence)
    return {
        schema = "PredicateResult",
        predicate = name,
        predicateVersion = "retro-generator-v1",
        inputDigest = hashText(name .. "|" .. stableString(value)),
        status = tostring(value),
        value = value,
        deterministic = true,
        ownerModule = "scenario_tooling.retro_generator",
        evidence = evidence or {}
    }
end

local function composeState(finisher, cells, turnLimit, scenarioTurn)
    local decoyName = finisher.unitType
    local units = {
        unit("blue_finisher", finisher.unitType, BLUE, cells.start.row, cells.start.col, 1),
        unit("red_commandant", "Commandant", RED, cells.commandant.row, cells.commandant.col, finisher.damageVsCommandant),
        unit("red_decoy", decoyName, RED, cells.decoy.row, cells.decoy.col, HP_BY_UNIT[decoyName])
    }
    if cells.rock then
        units[#units + 1] = unit("neutral_rock", "Rock", NEUTRAL, cells.rock.row, cells.rock.col, HP_BY_UNIT.Rock)
    end
    return {
        schema = "ScenarioState",
        board = { rows = 8, cols = 8 },
        currentPlayer = BLUE,
        scenarioTurn = scenarioTurn,
        turnLimit = turnLimit,
        maxActionsPerTurn = CONTRACT_MAX_ACTIONS_PER_TURN,
        objectiveType = "destroy_red_commandant_within_turn_limit",
        supplyEnabled = false,
        turnActions = 0,
        actionsUsed = 0,
        units = units
    }
end

local function findFinisherSpec(id)
    local finishers = finisherLibrary.listFinishers()
    local i
    for i = 1, #finishers do
        if finishers[i].id == id then
            return finishers[i]
        end
    end
    return nil
end

local function chooseRichContractLayout(seed, rng, profileId)
    local _ = seed
    profileId = profileId or "support_reposition_rock_los_finish"
    local variants = {
        "left_lane",
        "right_lane"
    }
    local index = rng.nextRange(1, #variants)
    return compositionLayoutConstraints.buildLayout(profileId, {
        variant = variants[index]
    })
end

local function composeRichContractState(finisher, layout, turnLimit, scenarioTurn)
    return {
        schema = "ScenarioState",
        board = { rows = 8, cols = 8 },
        currentPlayer = BLUE,
        scenarioTurn = scenarioTurn,
        turnLimit = turnLimit,
        maxActionsPerTurn = CONTRACT_MAX_ACTIONS_PER_TURN,
        objectiveType = "destroy_red_commandant_within_turn_limit",
        supplyEnabled = false,
        turnActions = 0,
        actionsUsed = 0,
        units = {
            unit("blue_a_support", "Artillery", BLUE, layout.supportStart.row, layout.supportStart.col, HP_BY_UNIT.Artillery),
            unit("blue_finisher", finisher.unitType, BLUE, layout.finisherStart.row, layout.finisherStart.col, HP_BY_UNIT[finisher.unitType]),
            unit("red_commandant", "Commandant", RED, layout.commandant.row, layout.commandant.col, finisher.damageVsCommandant),
            unit("red_decoy", "Crusher", RED, layout.decoy.row, layout.decoy.col, HP_BY_UNIT.Crusher),
            unit("neutral_rock", "Rock", NEUTRAL, layout.rock.row, layout.rock.col, 2),
            unit("neutral_shortcut_rock", "Rock", NEUTRAL, layout.commandant.row + 1, layout.commandant.col, HP_BY_UNIT.Rock)
        }
    }
end

local function composeSupportPressureState(finisher, layout, turnLimit, scenarioTurn)
    return {
        schema = "ScenarioState",
        board = { rows = 8, cols = 8 },
        currentPlayer = BLUE,
        scenarioTurn = scenarioTurn,
        turnLimit = turnLimit,
        maxActionsPerTurn = CONTRACT_MAX_ACTIONS_PER_TURN,
        objectiveType = "destroy_red_commandant_within_turn_limit",
        supplyEnabled = false,
        turnActions = 0,
        actionsUsed = 0,
        units = {
            unit("blue_a_support", "Artillery", BLUE, layout.supportStart.row, layout.supportStart.col, 4),
            unit("blue_finisher", finisher.unitType, BLUE, layout.finisherStart.row, layout.finisherStart.col, HP_BY_UNIT[finisher.unitType]),
            unit("red_commandant", "Commandant", RED, layout.commandant.row, layout.commandant.col, finisher.damageVsCommandant),
            unit("red_decoy", "Crusher", RED, layout.decoy.row, layout.decoy.col, HP_BY_UNIT.Crusher),
            unit("red_support_threat", "Earthstalker", RED, layout.supportThreat.row, layout.supportThreat.col, HP_BY_UNIT.Earthstalker),
            unit("neutral_rock", "Rock", NEUTRAL, layout.rock.row, layout.rock.col, 2),
            unit("neutral_shortcut_rock", "Rock", NEUTRAL, layout.commandant.row + 1, layout.commandant.col, HP_BY_UNIT.Rock)
        }
    }
end

local function interceptorArtilleryLayout()
    return compositionLayoutConstraints.buildBaselineLayout("support_intercepts_finisher_threat_artillery_finish")
end

local function composeInterceptorArtilleryState(finisher, layout, turnLimit, scenarioTurn)
    return {
        schema = "ScenarioState",
        board = { rows = 8, cols = 8 },
        currentPlayer = BLUE,
        scenarioTurn = scenarioTurn,
        turnLimit = turnLimit,
        maxActionsPerTurn = CONTRACT_MAX_ACTIONS_PER_TURN,
        objectiveType = "destroy_red_commandant_within_turn_limit",
        supplyEnabled = false,
        turnActions = 0,
        actionsUsed = 0,
        units = {
            unit("blue_a_support", "Bastion", BLUE, layout.supportStart.row, layout.supportStart.col, HP_BY_UNIT.Bastion),
            unit("blue_finisher", finisher.unitType, BLUE, layout.finisherStart.row, layout.finisherStart.col, 4),
            unit("red_commandant", "Commandant", RED, layout.commandant.row, layout.commandant.col, finisher.damageVsCommandant),
            unit("red_interceptor", "Earthstalker", RED, layout.interceptor.row, layout.interceptor.col, 1)
        }
    }
end

local function dualRockLockLayout()
    return compositionLayoutConstraints.buildBaselineLayout("dual_rock_lock_ranged_finish")
end

local function composeDualRockLockState(finisher, layout, turnLimit, scenarioTurn)
    return {
        schema = "ScenarioState",
        board = { rows = 8, cols = 8 },
        currentPlayer = BLUE,
        scenarioTurn = scenarioTurn,
        turnLimit = turnLimit,
        maxActionsPerTurn = CONTRACT_MAX_ACTIONS_PER_TURN,
        objectiveType = "destroy_red_commandant_within_turn_limit",
        supplyEnabled = false,
        turnActions = 0,
        actionsUsed = 0,
        units = {
            unit("blue_a_support", "Artillery", BLUE, layout.supportStart.row, layout.supportStart.col, HP_BY_UNIT.Artillery),
            unit("blue_finisher", finisher.unitType, BLUE, layout.finisherStart.row, layout.finisherStart.col, HP_BY_UNIT[finisher.unitType]),
            unit("red_commandant", "Commandant", RED, layout.commandant.row, layout.commandant.col, finisher.damageVsCommandant),
            unit("neutral_lower_rock", "Rock", NEUTRAL, layout.lowerRock.row, layout.lowerRock.col, 2),
            unit("neutral_upper_rock", "Rock", NEUTRAL, layout.upperRock.row, layout.upperRock.col, 2)
        }
    }
end

local function crusherContactLayout()
    return compositionLayoutConstraints.buildBaselineLayout("crusher_contact_breach")
end

local function compositeSupportPressureCrusherLayout(opts)
    if type(opts) == "table" and (opts.layoutOffset or opts.layoutRowOffset or opts.layoutColOffset) then
        local offset = type(opts.layoutOffset) == "table" and opts.layoutOffset or {}
        local rowOffset = opts.layoutRowOffset or offset.rowOffset or offset.row or offset[1] or 0
        local colOffset = opts.layoutColOffset or offset.colOffset or offset.col or offset[2] or 0
        return compositionLayoutConstraints.buildTranslatedLayout(
            "composite_support_pressure_crusher_contact",
            rowOffset,
            colOffset
        )
    end
    return compositionLayoutConstraints.buildBaselineLayout("composite_support_pressure_crusher_contact")
end

local function composeCrusherContactState(finisher, layout, turnLimit, scenarioTurn)
    return {
        schema = "ScenarioState",
        board = { rows = 8, cols = 8 },
        currentPlayer = BLUE,
        scenarioTurn = scenarioTurn,
        turnLimit = turnLimit,
        maxActionsPerTurn = CONTRACT_MAX_ACTIONS_PER_TURN,
        objectiveType = "destroy_red_commandant_within_turn_limit",
        supplyEnabled = false,
        turnActions = 0,
        actionsUsed = 0,
        units = {
            unit("blue_a_support", "Earthstalker", BLUE, layout.supportStart.row, layout.supportStart.col, HP_BY_UNIT.Earthstalker),
            unit("blue_finisher", finisher.unitType, BLUE, layout.finisherStart.row, layout.finisherStart.col, HP_BY_UNIT[finisher.unitType]),
            unit("red_commandant", "Commandant", RED, layout.commandant.row, layout.commandant.col, finisher.damageVsCommandant),
            unit("red_contact_blocker", "Earthstalker", RED, layout.contactBlocker.row, layout.contactBlocker.col, HP_BY_UNIT.Earthstalker),
            unit("red_decoy", "Wingstalker", RED, layout.pressureDecoy.row, layout.pressureDecoy.col, HP_BY_UNIT.Wingstalker)
        }
    }
end

local function composeCompositeSupportPressureCrusherState(finisher, layout, turnLimit, scenarioTurn)
    return {
        schema = "ScenarioState",
        board = { rows = 8, cols = 8 },
        currentPlayer = BLUE,
        scenarioTurn = scenarioTurn,
        turnLimit = turnLimit,
        maxActionsPerTurn = CONTRACT_MAX_ACTIONS_PER_TURN,
        objectiveType = "destroy_red_commandant_within_turn_limit",
        supplyEnabled = false,
        turnActions = 0,
        actionsUsed = 0,
        units = {
            unit("blue_a_support", "Earthstalker", BLUE, layout.supportStart.row, layout.supportStart.col, HP_BY_UNIT.Earthstalker),
            unit("blue_finisher", finisher.unitType, BLUE, layout.finisherStart.row, layout.finisherStart.col, HP_BY_UNIT[finisher.unitType]),
            unit("red_commandant", "Commandant", RED, layout.commandant.row, layout.commandant.col, finisher.damageVsCommandant),
            unit("red_contact_blocker", "Bastion", RED, layout.contactBlocker.row, layout.contactBlocker.col, 3),
            unit("red_support_threat", "Earthstalker", RED, layout.pressureStart.row, layout.pressureStart.col, HP_BY_UNIT.Earthstalker)
        }
    }
end

local function hasUnitAt(units, row, col)
    local i
    for i = 1, #(units or {}) do
        local u = units[i]
        if tonumber(u.row) == row and tonumber(u.col) == col and (tonumber(u.currentHp) or 0) > 0 then
            return true
        end
    end
    return false
end

local function moveExistsFor(state, actorId, row, col)
    local legal = stateEngine.getLegalActions(state)
    local move = findAction(legal, function(a)
        return a.type == "move"
            and stableString(a.actorId) == stableString(actorId)
            and a.to
            and tonumber(a.to.row) == row
            and tonumber(a.to.col) == col
    end)
    return move
end

local function attackExistsFor(state, actorId, targetId)
    local legal = stateEngine.getLegalActions(state)
    local attack = findAction(legal, function(a)
        return a.type == "attack"
            and stableString(a.actorId) == stableString(actorId)
            and stableString(a.targetId) == stableString(targetId)
    end)
    return attack
end

local function buildScenarioRedPolicyConfig(seed, requiredCells, criticalBlueUnitIds)
    return {
        runtime = "scenarioRedRuntime",
        policy = "scenarioRedPolicy",
        policyVersion = redPolicy.VERSION,
        policyHash = redPolicy.POLICY_HASH,
        seed = seed,
        requiredCells = cloneCells(requiredCells),
        criticalBlueUnitIds = cloneIdList(criticalBlueUnitIds)
    }
end

local function appendCanonical(line, action)
    line[#line + 1] = canonicalAction(action)
end

local findUnitById

local function applyLineAction(state, line, action)
    appendCanonical(line, action)
    local nextState, result = stateEngine.applyAction(state, action)
    if type(result) ~= "table" or result.ok ~= true then
        return nil, "line_action_apply_failed"
    end
    return nextState, nil
end

local function advanceRedTurnWithPolicy(state, line, policyConfig)
    local cursor = state
    if cursor.currentPlayer == BLUE then
        local err
        cursor, err = applyLineAction(cursor, line, { type = "end_turn" })
        if not cursor then
            return nil, err
        end
    end
    if cursor.currentPlayer ~= RED then
        return nil, "red_policy_expected_red_turn"
    end

    local maxSteps = (tonumber(cursor.maxActionsPerTurn) or CONTRACT_MAX_ACTIONS_PER_TURN) + 1
    local step
    for step = 1, maxSteps do
        if cursor.currentPlayer ~= RED then
            return cursor, nil
        end
        local action = redPolicy.chooseAction(cursor, policyConfig)
        if type(action) ~= "table" then
            return nil, "red_policy_no_action"
        end
        local err
        cursor, err = applyLineAction(cursor, line, action)
        if not cursor then
            return nil, err
        end
    end

    if cursor.currentPlayer == RED then
        return nil, "red_policy_turn_did_not_end"
    end
    return cursor, nil
end

local function replayPolicyPlan(state, policyConfig)
    local cursor = stateEngine.normalize(state)
    local firstAction, record = redPolicy.chooseAction(cursor, policyConfig)
    local plan = record and record.selectedPlan and record.selectedPlan.actions or { firstAction }
    local applied = {}
    local i
    for i = 1, #(plan or {}) do
        local action = plan[i]
        if type(action) == "table" then
            local nextState, result = stateEngine.applyAction(cursor, action)
            if type(result) ~= "table" or result.ok ~= true then
                return nil, record, applied, "policy_plan_apply_failed"
            end
            cursor = nextState
            applied[#applied + 1] = canonicalAction(action)
            if cursor.currentPlayer ~= RED then
                break
            end
        end
    end
    return cursor, record, applied, nil
end

local function policyPlanKillsUnit(state, policyConfig, unitId)
    local nextState, record, applied, err = replayPolicyPlan(state, policyConfig)
    if not nextState then
        return false, record, applied, err
    end
    local unitAfter = findUnitById(nextState, unitId)
    return unitAfter == nil or (tonumber(unitAfter.currentHp) or 0) <= 0, record, applied, nil
end

function findUnitById(state, unitId)
    local s = stateEngine.normalize(state)
    local i
    for i = 1, #(s.units or {}) do
        if stableString(s.units[i].id) == stableString(unitId) then
            return s.units[i]
        end
    end
    return nil
end

local function resetBlueProbeTurn(state)
    local s = stateEngine.cloneState(stateEngine.normalize(state))
    s.currentPlayer = BLUE
    s.turnActions = 0
    s.actionsUsed = 0
    local i
    for i = 1, #(s.units or {}) do
        local u = s.units[i]
        if tonumber(u.player) == BLUE then
            u.hasMoved = false
            u.hasActed = false
            u.actionsUsed = 0
            u.turnActions = {}
        end
    end
    return stateEngine.normalize(s)
end

local function canActorAttackTargetWithinOneBlueTurn(state, actorId, targetId)
    local start = resetBlueProbeTurn(state)
    if attackExistsFor(start, actorId, targetId) then
        return true
    end
    local legal = stateEngine.getLegalActions(start)
    local i
    for i = 1, #legal do
        local action = legal[i]
        if action.type == "move" and stableString(action.actorId) == stableString(actorId) then
            local afterMove = stateEngine.applyAction(start, action)
            if attackExistsFor(afterMove, actorId, targetId) then
                return true
            end
        end
    end
    return false
end

local function replayLineStrict(state, line)
    local cursor = stateEngine.normalize(state)
    local replay = {
        initialStateHash = stateEngine.stateHash(cursor),
        applied = {}
    }
    local i
    for i = 1, #(line or {}) do
        local wanted = line[i]
        local legal = stateEngine.getLegalActions(cursor)
        local chosen = nil
        local j
        for j = 1, #legal do
            if actionMatches(legal[j], wanted) then
                chosen = legal[j]
                break
            end
        end
        if not chosen then
            return nil, {
                ok = false,
                reason = "line_action_not_legal",
                failingIndex = i,
                attempted = wanted
            }
        end
        cursor = stateEngine.applyAction(cursor, chosen)
        replay.applied[#replay.applied + 1] = {
            action = canonicalAction(chosen),
            stateHash = stateEngine.stateHash(cursor)
        }
    end
    return cursor, replay
end

local function proveRichFalseLineByTempo(candidate, line)
    if type(candidate) ~= "table" or candidate.contractPattern ~= "support_reposition_rock_los_finish" then
        return nil
    end
    local first = line and line[1] or nil
    if type(first) ~= "table" or first.type ~= "move" or stableString(first.actorId) ~= "blue_a_support" then
        return nil
    end

    local cursor, replay = replayLineStrict(candidate.scenarioState, line)
    if not cursor then
        return nil
    end
    local rock = findUnitById(cursor, "neutral_rock")
    if not rock or (tonumber(rock.currentHp) or 0) <= 0 then
        return nil
    end

    local supportCanClearNextTurn = canActorAttackTargetWithinOneBlueTurn(cursor, "blue_a_support", "neutral_rock")
    if supportCanClearNextTurn then
        return nil
    end

    return {
        status = "false_line_proven",
        reason = "support_wrong_cell_breaks_next_turn_rock_clear",
        replay = replay,
        proof = {
            status = "tempo_lower_bound_proven",
            proofMode = "support_rock_clear_reachability",
            supportCanClearRockNextBlueTurn = false,
            requiredRockId = "neutral_rock",
            supportId = "blue_a_support",
            finisherId = "blue_finisher",
            turnLimit = candidate.scenarioState and candidate.scenarioState.turnLimit,
            maxActionsPerTurn = candidate.scenarioState and candidate.scenarioState.maxActionsPerTurn
        }
    }
end

local function buildStartCandidates(attackCell, commandantCell, rng)
    local candidates = {}
    local deltas = {
        { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
        { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 },
        { 3, 0 }, { -3, 0 }, { 0, 3 }, { 0, -3 }
    }
    local i
    for i = 1, #deltas do
        local row = attackCell.row + deltas[i][1]
        local col = attackCell.col + deltas[i][2]
        if inBounds(row, col) and not (row == commandantCell.row and col == commandantCell.col) then
            candidates[#candidates + 1] = { row = row, col = col }
        end
    end
    shuffleInPlace(candidates, rng)
    return candidates
end

local function buildDecoyCandidates(forbiddenCells, rng)
    local cells = allBoardCells()
    shuffleInPlace(cells, rng)
    local out = {}
    local i
    for i = 1, #cells do
        local c = cells[i]
        if not forbiddenCells[cellKey(c.row, c.col)] then
            out[#out + 1] = c
        end
    end
    return out
end

local function buildRockCell(forbiddenCells, rng)
    local cells = buildDecoyCandidates(forbiddenCells, rng)
    if #cells == 0 then
        return nil
    end
    return cells[1]
end

local function cellsFromSupported(finisher, rng)
    local supported = finisherLibrary.supportedCommandantCells(finisher.id)
    local out = {}
    local i
    for i = 1, #(supported or {}) do
        local c = supported[i]
        if type(c) == "table" and inBounds(tonumber(c.row) or -1, tonumber(c.col) or -1) then
            out[#out + 1] = { row = tonumber(c.row), col = tonumber(c.col) }
        end
    end
    shuffleInPlace(out, rng)
    return out
end

local function selectMicroInteractions(finisher, rng)
    local all = microLibrary.listMicroInteractions()
    local allowed = {}
    local i
    for i = 1, #all do
        local spec = all[i]
        if not hasMacroField(spec) and not microLibrary.isMacroTemplate(spec) then
            local okFamily = false
            local j
            for j = 1, #(spec.allowedFinisherFamilies or {}) do
                if spec.allowedFinisherFamilies[j] == finisher.family then
                    okFamily = true
                    break
                end
            end
            if okFamily then
                allowed[#allowed + 1] = spec.id
            end
        end
    end

    local chosen = {}
    local function pushIfPresent(id)
        local k
        for k = 1, #allowed do
            if allowed[k] == id then
                local exists = false
                local z
                for z = 1, #chosen do
                    if chosen[z] == id then
                        exists = true
                        break
                    end
                end
                if not exists then
                    chosen[#chosen + 1] = id
                end
                return
            end
        end
    end

    pushIfPresent("FINISHER_CELL_GAIN")
    pushIfPresent("WRONG_TARGET_TEMPO_LOSS")
    pushIfPresent("ORDER_DEPENDENCY")

    if #chosen < 3 then
        shuffleInPlace(allowed, rng)
        for i = 1, #allowed do
            pushIfPresent(allowed[i])
            if #chosen >= 3 then
                break
            end
        end
    end
    return chosen
end

local function buildFingerprint(candidate)
    local state = candidate.scenarioState or {}
    local units = state.units or {}
    local unitBits = {}
    local i
    for i = 1, #units do
        local u = units[i]
        unitBits[#unitBits + 1] = table.concat({
            stableString(u.id),
            stableString(u.name),
            stableString(u.player),
            stableString(u.row),
            stableString(u.col),
            stableString(u.currentHp)
        }, ":")
    end
    table.sort(unitBits)

    local microSig = table.concat(candidate.microInteractions or {}, ">")
    local geom = table.concat({
        stableString(candidate.commandantCellText),
        stableString(candidate.attackCellText),
        stableString(candidate.startCellText),
        stableString(candidate.decoyCellText),
        stableString(candidate.rockCellText or "")
    }, "|")
    local raw = table.concat({
        stableString(candidate.seed),
        stableString(candidate.finisher.id),
        stableString(candidate.finisher.family),
        microSig,
        geom,
        table.concat(unitBits, ";")
    }, "||")
    local novelty = ((tonumber(hashText(raw), 16) % 997) / 997)
    local roleSignature = candidate.finisher.unitType .. "+lethal_decoy"
    local pressureSignature = "red_decoy_can_kill_low_hp_finisher_after_wrong_target"
    local falseLineSignature = "wrong_target_tempo_loss"
    if candidate.contractPattern == "composite_support_pressure_crusher_contact" then
        roleSignature = candidate.finisher.unitType .. "+composite+support_pressure+contact_breach+melee_blocker"
        pressureSignature = "red_support_threat_can_move_attack_support_if_blue_skips_setup"
        falseLineSignature = "skip_support_setup_loses_support_then_contact_tempo"
    elseif candidate.contractPattern == "crusher_contact_breach" then
        roleSignature = candidate.finisher.unitType .. "+contact_breach+melee_blocker+tempo_decoy"
        pressureSignature = "contact_blocker_and_decoy_force_melee_tempo_accounting"
        falseLineSignature = "wrong_contact_target_or_skip_loses_melee_tempo"
    elseif candidate.contractPattern == "support_under_real_red_pressure" then
        roleSignature = candidate.finisher.unitType .. "+support_artillery+earthstalker_pressure+rock_lock"
        pressureSignature = "red_earthstalker_can_move_attack_support_if_blue_loses_tempo"
        falseLineSignature = "red_attacks_support_after_tempo_loss"
    elseif candidate.contractPattern == "support_reposition_rock_los_finish" then
        roleSignature = candidate.finisher.unitType .. "+support_artillery+rock_lock+tempo_decoy"
        pressureSignature = "red_decoy_is_legal_wrong_target_that_consumes_final_turn"
    elseif candidate.contractPattern == "support_intercepts_finisher_threat_artillery_finish" then
        roleSignature = candidate.finisher.unitType .. "+support_interceptor+finisher_pressure+artillery_lane"
        pressureSignature = "red_interceptor_can_move_attack_artillery_if_blue_skips_intercept"
        falseLineSignature = "skip_support_intercept_loses_critical_finisher"
    elseif candidate.contractPattern == "dual_rock_lock_ranged_finish" then
        roleSignature = candidate.finisher.unitType .. "+dual_rock_lock_chain+ranged_payoff"
        pressureSignature = "two_rock_locks_force_support_tempo_before_ranged_payoff"
        falseLineSignature = "skip_or_single_lock_clear_loses_dual_lock_tempo"
    end
    return {
        schema = "TacticalFingerprint",
        fingerprint_version = "retro_generator_core_v1",
        mechanism_family = pickMechanismFamily(candidate.finisher.family),
        micro_sequence_signature = microSig,
        role_signature = roleSignature,
        pressure_signature = pressureSignature,
        false_line_signature = falseLineSignature,
        geometry_signature = geom,
        noveltyScore = novelty,
        hash = hashText(raw)
    }
end

local function buildVarietyFeatures(candidate)
    local s = candidate.scenarioState
    local fin = nil
    local cmd = nil
    local i
    for i = 1, #(s.units or {}) do
        local u = s.units[i]
        if u.id == "blue_finisher" then
            fin = u
        elseif u.id == "red_commandant" then
            cmd = u
        end
    end
    local dist = 0
    if fin and cmd then
        dist = math.abs(fin.row - cmd.row) + math.abs(fin.col - cmd.col)
    end
    local quadrants = {}
    for i = 1, #(s.units or {}) do
        local u = s.units[i]
        local qr = (u.row <= 4) and 0 or 1
        local qc = (u.col <= 4) and 0 or 1
        quadrants[qr .. qc] = true
    end
    local quadCount = tableLength(quadrants)
    local score = (math.min(dist, 8) / 8) * 0.45 + (quadCount / 4) * 0.35 + ((#(candidate.microInteractions or {})) / 3) * 0.20
    return {
        distanceFinisherToCommandant = dist,
        occupiedQuadrants = quadCount,
        microCount = #(candidate.microInteractions or {}),
        score = score,
        pass = score >= 0.40
    }
end

local function buildMechanismSpec(candidate, proofDomain)
    local hints = {
        SUPPORT_CELL_GAIN = {
            role = "support_position",
            localActionHint = "move support to the enabling cell before spending the key attack"
        },
        ROCK_AS_LOCK = {
            role = "lock_key",
            localActionHint = "destroy the Rock that blocks the finisher lane"
        },
        LOS_OPEN_RANGED = {
            role = "line_open",
            localActionHint = "convert the blocked ranged line into a legal Cloudstriker shot"
        },
        FINISHER_CELL_GAIN = {
            role = "finisher_position",
            localActionHint = "move finisher to the required attack cell after the lane is open"
        },
        WRONG_TARGET_TEMPO_LOSS = {
            role = "false_target",
            localActionHint = "ignore the decoy because attacking it consumes the final turn"
        },
        RED_ATTACKS_SUPPORT = {
            role = "red_pressure",
            localActionHint = "respect the support timing before Red can remove it"
        },
        RED_ATTACKS_FINISHER = {
            role = "red_finisher_pressure",
            localActionHint = "intercept the Red unit before it can remove the finisher"
        }
    }
    local chain = {}
    local i
    for i = 1, #(candidate.microInteractions or {}) do
        local id = candidate.microInteractions[i]
        local hint = hints[id] or {
            role = "micro",
            localActionHint = "resolve local micro-interaction " .. stableString(id)
        }
        chain[#chain + 1] = {
            id = id,
            role = hint.role,
            localActionHint = hint.localActionHint
        }
    end
    local contactBreach = candidate.contractPattern == "crusher_contact_breach"
        or candidate.contractPattern == "composite_support_pressure_crusher_contact"
    local rich = candidate.contractPattern == "support_reposition_rock_los_finish"
        or candidate.contractPattern == "support_under_real_red_pressure"
    local supportPressure = candidate.contractPattern == "support_under_real_red_pressure"
    local lockText = "finisher_not_yet_on_winning_cell"
    local keyText = "single finisher reposition to exact attack cell"
    local pathText = "move_then_attack_before_red_decoy_gets_turn"
    local riskText = "wrong target consumes finisher action and gives Red a lethal decoy reply"
    if rich then
        lockText = "Rock blocks the Cloudstriker line and support starts outside the key cell."
        keyText = "Support gains the key cell, destroys the Rock, then finisher gains the exact LOS cell."
        pathText = "support_move_then_rock_clear_then_finisher_cell_gain_then_commandant_shot"
        riskText = "wrong target consumes the last-turn finisher action and leaves no forced win."
    end
    if supportPressure then
        lockText = "Rock blocks the Cloudstriker line while Earthstalker threatens the support if Blue loses tempo."
        keyText = "Support must gain the key cell and clear Rock before Red can remove it."
        pathText = "support_move_then_rock_clear_then_red_pressure_then_finisher_cell_gain_then_commandant_shot"
        riskText = "passing or drifting lets Red execute a move-attack on support before the enabling interaction resolves."
    end
    if candidate.contractPattern == "support_intercepts_finisher_threat_artillery_finish" then
        lockText = "A Red interceptor can move-attack the fragile Artillery finisher if Blue skips support interception."
        keyText = "Support must gain the intercept cell and remove the interceptor before Artillery starts staging."
        pathText = "support_intercept_then_artillery_staging_then_final_orthogonal_payoff"
        riskText = "advancing Artillery first lets Red remove the only finisher before the exact firing cell is reached."
    end
    if candidate.contractPattern == "dual_rock_lock_ranged_finish" then
        lockText = "Two separate Rocks block the Cloudstriker line, and one support action cannot open both locks."
        keyText = "Support must convert the lower Rock lock, then the upper Rock lock, before the finisher cell matters."
        pathText = "lower_rock_lock_then_upper_rock_lock_then_cloudstriker_payoff"
        riskText = "skipping either lock or moving the finisher early leaves the ranged line blocked or the action budget short."
    end
    if contactBreach then
        lockText = "Crusher is too far from melee contact and the contact lane is occupied by a live blocker."
        keyText = "Blue must preserve enough tempo for the Crusher to breach into the adjacent contact cell."
        pathText = "contact_blocker_tempo_then_crusher_staging_then_adjacent_contact_attack"
        riskText = "attacking the wrong contact target or drifting loses the melee action budget before the turn limit."
    end
    if candidate.contractPattern == "composite_support_pressure_crusher_contact" then
        lockText = "A separate Red pressure unit can move-attack support if Blue skips setup, while a different blocker occupies Crusher contact."
        keyText = "Support must escape pressure by clearing the blocker first, then Crusher must still gain melee contact."
        pathText = "support_pressure_answer_then_contact_breach_then_adjacent_crusher_payoff"
        riskText = "passing or drifting lets Red remove support; attacking pressure first is not free, while early Crusher tempo cannot finish inside the turn limit."
    end

    return {
        schema = "MechanismSpec",
        mechanism_id = "retro_mechanism_" .. hashText(stableString(candidate.seed) .. "|" .. candidate.finisher.id),
        family = pickMechanismFamily(candidate.finisher.family),
        lock = lockText,
        key = keyText,
        path = pathText,
        risk = riskText,
        payoff = "destroy_red_commandant_within_turn_limit",
        proofDomain = proofDomain,
        micro_interactions = shallowCopyArray(candidate.microInteractions),
        localChain = chain
    }
end

local function buildRejection(code, category, message, evidence)
    return {
        code = code,
        category = category,
        message = message,
        blocking = true,
        evidence_refs = evidence and { evidence } or {}
    }
end

local function compositeContractIssue(candidate)
    if type(candidate) ~= "table" or candidate.contractPattern ~= "composite_support_pressure_crusher_contact" then
        return nil
    end

    local evidence = candidate.contractEvidence or {}
    local pressureUnit = stableString(evidence.redPressureUnit)
    local blockerUnit = stableString(evidence.contactBlockerUnit)
    if pressureUnit == "" or blockerUnit == "" then
        return {
            code = "composite_missing_role_evidence",
            message = "Composite candidates must declare separate pressure and blocker roles.",
            evidence = evidence
        }
    end
    if pressureUnit == blockerUnit or evidence.contactBlockerAlsoPressure == true then
        return {
            code = "composite_pressure_blocker_same_unit",
            message = "Support pressure and contact blocker cannot be satisfied by the same Red unit.",
            evidence = evidence
        }
    end

    local firstAction = candidate.expectedWinningPrefix and candidate.expectedWinningPrefix[1] or nil
    if type(firstAction) == "table" and firstAction.type == "attack" then
        local targetId = stableString(firstAction.targetId)
        if targetId == pressureUnit or targetId == blockerUnit then
            return {
                code = "composite_too_obvious_first_move",
                message = "Composite candidate first move cannot simply kill the pressure/blocker role.",
                evidence = {
                    firstAction = firstAction,
                    pressureUnit = pressureUnit,
                    blockerUnit = blockerUnit
                }
            }
        end
    end

    if evidence.pressureCanBeAttackedAtStart == true then
        return {
            code = "composite_pressure_free_to_remove",
            message = "Composite pressure cannot be immediately removable by the setup support at the start.",
            evidence = evidence
        }
    end

    local compositionalContract = candidate.compositionalContract or {}
    local actionConsequences = compositionalContract.actionConsequences or candidate.actionConsequences or {}
    local expectedBySignature = {}
    local expectedCount = 0
    for _, action in ipairs(candidate.expectedWinningPrefix or {}) do
        local actorId = stableString(action and action.actorId)
        if type(action) == "table" and action.type ~= "end_turn" and actorId:find("^blue_", 1, false) ~= nil then
            expectedBySignature[actionSignature(action)] = true
            expectedCount = expectedCount + 1
        end
    end
    if expectedCount == 0 or #actionConsequences < expectedCount then
        return {
            code = "composite_missing_action_consequence_evidence",
            message = "Composite candidates must prove every key Blue action changes the solution contract.",
            evidence = {
                expectedActionCount = expectedCount,
                consequenceCount = #actionConsequences
            }
        }
    end

    local provenBySignature = {}
    for _, result in ipairs(actionConsequences) do
        local signature = stableString(result.actionSignature)
        local proven = result.proven == true or result.status == "proven"
        local changed = result.changed == true
        local changedOutputs = result.changed_outputs
            or (result.delta_metrics and result.delta_metrics.changed_outputs)
            or {}
        if expectedBySignature[signature] and proven and changed and type(changedOutputs) == "table" and #changedOutputs > 0 then
            provenBySignature[signature] = true
        end
    end
    for signature in pairs(expectedBySignature) do
        if not provenBySignature[signature] then
            return {
                code = "composite_unproven_action_consequence",
                message = "Composite action consequence evidence is missing, unknown, or non-changing.",
                evidence = {
                    missingActionSignature = signature,
                    consequences = actionConsequences
                }
            }
        end
    end

    return nil
end

local function buildProofCertificate(candidate, solveProof, falseLines, proofDomain)
    local schemaVersion = schemaContract.freeze and schemaContract.freeze.version or "unknown"
    local predicateVersion = predicateContract.module and predicateContract.module.version or "unknown"
    local winning = shallowCopyArray(solveProof and solveProof.winningLine or {})
    local certificate = {
        schema = "ProofCertificate",
        seed = candidate.seed,
        contract_version = schemaVersion,
        contract_hash = hashText(schemaVersion .. "|" .. predicateVersion),
        rules_version = solveProof and solveProof.proofCertificate and solveProof.proofCertificate.rulesKernelVersion or "unknown",
        rules_hash = solveProof and solveProof.proofCertificate and solveProof.proofCertificate.initialStateHash or "unknown",
        policy_version = solveProof and solveProof.proofCertificate and solveProof.proofCertificate.redPolicyVersion or "unknown",
        policy_hash = solveProof and solveProof.proofCertificate and solveProof.proofCertificate.redPolicyHash or "unknown",
        initial_state = stateEngine.stateHash(candidate.scenarioState),
        turn_limit = candidate.scenarioState.turnLimit,
        max_actions_per_turn = candidate.scenarioState.maxActionsPerTurn,
        winning_line = winning,
        red_responses = shallowCopyArray(solveProof and solveProof.refutations or {}),
        proof_domain_version = proofDomain,
        proof_domain_hash = hashText(proofDomain),
        search_result = solveProof and solveProof.status or "unknown",
        searchResult = solveProof and solveProof.status or "unknown",
        false_lines = falseLines or {},
        predicate_versions = {
            predicateContract = predicateVersion
        },
        tactical_fingerprint = candidate.tacticalFingerprint and candidate.tacticalFingerprint.hash or "unknown",
        solverCertificate = solveProof and solveProof.proofCertificate or nil
    }
    if proofDomain == "defensive" and solveProof and solveProof.defensiveDomainDecisions then
        certificate.defensive_domain_decisions = solveProof.defensiveDomainDecisions
    end
    return certificate
end

local function packQuality(candidate, variety, noveltyThreshold, certified)
    local novelty = candidate.tacticalFingerprint.noveltyScore or 0
    local reasons = {}
    if novelty < noveltyThreshold then
        reasons[#reasons + 1] = "novelty_below_threshold"
    end
    if not variety.pass then
        reasons[#reasons + 1] = "native_variety_low"
    end
    return {
        qualityFeatures = {
            nativeVariety = variety,
            novelty = {
                score = novelty,
                threshold = noveltyThreshold,
                pass = novelty >= noveltyThreshold
            },
            certified = certified
        },
        qualityFeatureSet = {
            schema = "QualityFeatureSet",
            feature_version = "retro_generator_v1",
            features = {
                native_variety_score = variety.score,
                novelty_score = novelty
            },
            component_scores = {
                native_variety = variety.score,
                novelty = novelty
            },
            total_score = (variety.score + novelty) / 2,
            pass = certified,
            reasons = reasons
        }
    }
end

local function composeRichContractCandidateFromSeed(seed, opts)
    local turnLimit = normalizeTurnLimit(opts)
    local scenarioTurn = tonumber(opts and opts.scenarioTurn) or DEFAULT_SCENARIO_TURN
    if scenarioTurn < 1 then
        scenarioTurn = 1
    end
    if scenarioTurn > turnLimit then
        scenarioTurn = turnLimit
    end

    local finisher = findFinisherSpec("cloudstriker_ranged")
    if not finisher then
        return nil, "cloudstriker_finisher_missing"
    end

    local rng = makeRng(seed)
    local layout = chooseRichContractLayout(seed, rng)
    local state = composeRichContractState(finisher, layout, turnLimit, scenarioTurn)
    local finisherStagingCell = layout.finisherStaging or { row = layout.attack.row + 1, col = layout.attack.col }
    local requiredCells = cloneCells(layout.requiredCells)
    if #requiredCells == 0 then
        requiredCells = {
            { row = layout.supportKey.row, col = layout.supportKey.col },
            { row = layout.attack.row, col = layout.attack.col }
        }
    end
    local criticalBlueUnitIds = cloneIdList(layout.criticalBlueUnitIds)
    if #criticalBlueUnitIds == 0 then
        criticalBlueUnitIds = { "blue_finisher", "blue_a_support" }
    end
    local policyConfig = buildScenarioRedPolicyConfig(seed, requiredCells, criticalBlueUnitIds)

    local supportMove = moveExistsFor(state, "blue_a_support", layout.supportKey.row, layout.supportKey.col)
    local supportAttackAtStart = attackExistsFor(state, "blue_a_support", "neutral_rock")
    local falseDecoyAttack = attackExistsFor(state, "blue_finisher", "red_decoy")
    local finisherMoveDirectAtStart = moveExistsFor(state, "blue_finisher", layout.attack.row, layout.attack.col)
    local wrongSupportMove = nil
    local wrongSupportScore = -1
    local initialLegal = stateEngine.getLegalActions(state)
    local wi
    for wi = 1, #initialLegal do
        local a = initialLegal[wi]
        if a.type == "move"
            and stableString(a.actorId) == "blue_a_support"
            and not (a.to and tonumber(a.to.row) == layout.supportKey.row and tonumber(a.to.col) == layout.supportKey.col) then
            local distanceFromKey = math.abs((tonumber(a.to.row) or 0) - layout.supportKey.row)
                + math.abs((tonumber(a.to.col) or 0) - layout.supportKey.col)
            if distanceFromKey > wrongSupportScore then
                wrongSupportScore = distanceFromKey
                wrongSupportMove = a
            end
        end
    end
    if not supportMove or supportAttackAtStart or finisherMoveDirectAtStart or not inBounds(finisherStagingCell.row, finisherStagingCell.col) then
        return nil, "rich_contract_precondition_failed"
    end

    local afterSupportMove = stateEngine.applyAction(state, supportMove)
    local supportRockAttack = attackExistsFor(afterSupportMove, "blue_a_support", "neutral_rock")
    if not supportRockAttack then
        return nil, "support_rock_attack_missing"
    end

    local afterRockClear = stateEngine.applyAction(afterSupportMove, supportRockAttack)
    local expectedWinningPrefix = {
        canonicalAction(supportMove),
        canonicalAction(supportRockAttack)
    }
    local turn2BlueStart, redTurnErr = advanceRedTurnWithPolicy(afterRockClear, expectedWinningPrefix, policyConfig)
    if not turn2BlueStart then
        return nil, redTurnErr or "red_policy_turn1_failed"
    end

    local finisherStagingMove = moveExistsFor(turn2BlueStart, "blue_finisher", finisherStagingCell.row, finisherStagingCell.col)
    if not finisherStagingMove then
        return nil, "finisher_staging_move_missing"
    end
    local afterStaging = stateEngine.applyAction(turn2BlueStart, finisherStagingMove)
    local finisherAttackFromStaging = attackExistsFor(afterStaging, "blue_finisher", "red_commandant")
    if finisherAttackFromStaging then
        return nil, "finisher_staging_already_wins"
    end

    appendCanonical(expectedWinningPrefix, finisherStagingMove)
    local turn3BlueStart, redTurn2Err = advanceRedTurnWithPolicy(afterStaging, expectedWinningPrefix, policyConfig)
    if not turn3BlueStart then
        return nil, redTurn2Err or "red_policy_turn2_failed"
    end

    local finisherMove = moveExistsFor(turn3BlueStart, "blue_finisher", layout.attack.row, layout.attack.col)
    if not finisherMove then
        return nil, "finisher_required_cell_missing"
    end

    local commandantAttackBeforeFinisherMove = attackExistsFor(turn3BlueStart, "blue_finisher", "red_commandant")
    local afterFinisherMove = stateEngine.applyAction(turn3BlueStart, finisherMove)
    local commandantAttack = attackExistsFor(afterFinisherMove, "blue_finisher", "red_commandant")
    if not commandantAttack then
        return nil, "finisher_commandant_attack_missing"
    end

    local outcomeBeforeFinalAttack = stateEngine.evaluateOutcome(afterFinisherMove)
    local afterWin, winResult = stateEngine.applyAction(afterFinisherMove, commandantAttack)
    local outcome = stateEngine.evaluateOutcome(afterWin)
    if type(winResult) ~= "table" or winResult.ok ~= true or outcome.status ~= "blue_win" then
        return nil, "rich_contract_not_immediate_win"
    end
    appendCanonical(expectedWinningPrefix, finisherMove)
    appendCanonical(expectedWinningPrefix, commandantAttack)

    local actionConsequences = {
        compositionComposer.buildActionConsequence(
            "support_reposition_rock_los_finish",
            "support_los_setup_move",
            {
                seed = seed,
                actionIndex = 1,
                action = supportMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(state),
                afterStateHash = stateEngine.stateHash(afterSupportMove),
                evidence = {
                    attackBeforeMove = supportAttackAtStart ~= nil,
                    attackAfterMove = supportRockAttack ~= nil,
                    requiredSupportCell = formatCell(layout.supportKey.row, layout.supportKey.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "support_reposition_rock_los_finish",
            "support_rock_clear_attack",
            {
                seed = seed,
                actionIndex = 2,
                action = supportRockAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterSupportMove),
                afterStateHash = stateEngine.stateHash(afterRockClear),
                evidence = {
                    rockUnit = "neutral_rock",
                    rockAfterClear = findUnitById(afterRockClear, "neutral_rock") ~= nil,
                    requiredFinisherCell = formatCell(layout.attack.row, layout.attack.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "support_reposition_rock_los_finish",
            "finisher_staging_move",
            {
                seed = seed,
                actionIndex = 3,
                action = finisherStagingMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn2BlueStart),
                afterStateHash = stateEngine.stateHash(afterStaging),
                evidence = {
                    attackFromStaging = finisherAttackFromStaging ~= nil,
                    requiredFinisherCell = formatCell(layout.attack.row, layout.attack.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "support_reposition_rock_los_finish",
            "finisher_los_cell_move",
            {
                seed = seed,
                actionIndex = 4,
                action = finisherMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn3BlueStart),
                afterStateHash = stateEngine.stateHash(afterFinisherMove),
                evidence = {
                    commandantAttackBeforeLosCell = commandantAttackBeforeFinisherMove ~= nil,
                    commandantAttackAfterLosCell = commandantAttack ~= nil
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "support_reposition_rock_los_finish",
            "commandant_payoff_attack",
            {
                seed = seed,
                actionIndex = 5,
                action = commandantAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterFinisherMove),
                afterStateHash = stateEngine.stateHash(afterWin),
                evidence = {
                    outcomeBefore = outcomeBeforeFinalAttack and outcomeBeforeFinalAttack.status or "unknown",
                    outcomeAfter = outcome and outcome.status or "unknown"
                }
            }
        )
    }
    local compositionalContract, compositionErr = compositionComposer.buildContract(
        "support_reposition_rock_los_finish",
        expectedWinningPrefix,
        actionConsequences,
        { seed = seed }
    )
    if not compositionalContract then
        return nil, type(compositionErr) == "string" and compositionErr or "rock_los_contract_build_failed"
    end
    local compositionOk = compositionComposer.validateContract(compositionalContract)
    if not compositionOk then
        return nil, "rock_los_contract_validation_failed"
    end

    local candidate = {
        seed = seed,
        finisher = finisher,
        scenarioState = state,
        contractPattern = "support_reposition_rock_los_finish",
        microInteractions = {
            "SUPPORT_CELL_GAIN",
            "ROCK_AS_LOCK",
            "LOS_OPEN_RANGED",
            "FINISHER_CELL_GAIN",
            "WRONG_TARGET_TEMPO_LOSS"
        },
        commandantCellText = formatCell(layout.commandant.row, layout.commandant.col),
        attackCellText = formatCell(layout.attack.row, layout.attack.col),
        startCellText = formatCell(layout.finisherStart.row, layout.finisherStart.col),
        decoyCellText = layout.decoy and formatCell(layout.decoy.row, layout.decoy.col) or "",
        rockCellText = formatCell(layout.rock.row, layout.rock.col),
        supportStartCellText = formatCell(layout.supportStart.row, layout.supportStart.col),
        supportKeyCellText = formatCell(layout.supportKey.row, layout.supportKey.col),
        expectedWinningPrefix = expectedWinningPrefix,
        preferredFalseLine = {
            { type = "end_turn" }
        },
        scenarioRedPolicy = policyConfig,
        compositionalContract = compositionalContract,
        actionConsequences = actionConsequences,
        contractEvidence = {
            layoutSpecId = layout.layoutSpecId,
            layoutSpecVersion = layout.layoutSpecVersion,
            layoutConstraintVersion = layout.layoutConstraintVersion,
            supportMustReposition = supportAttackAtStart == nil,
            rockBlocksFinisherShotBeforeClear = true,
            actionConsequences = actionConsequences,
            falseTargetAvailable = falseDecoyAttack ~= nil,
            requiredSupportCell = formatCell(layout.supportKey.row, layout.supportKey.col),
            requiredFinisherCell = formatCell(layout.attack.row, layout.attack.col),
            rockCell = formatCell(layout.rock.row, layout.rock.col),
            shortcutBlockerCell = formatCell(layout.commandant.row + 1, layout.commandant.col),
            commandantCell = formatCell(layout.commandant.row, layout.commandant.col)
        }
    }
    candidate.tacticalFingerprint = buildFingerprint(candidate)
    return candidate
end

local function composeSupportPressureCandidateFromSeed(seed, opts)
    local turnLimit = normalizeTurnLimit(opts)
    local scenarioTurn = tonumber(opts and opts.scenarioTurn) or DEFAULT_SCENARIO_TURN
    if scenarioTurn < 1 then
        scenarioTurn = 1
    end
    if scenarioTurn > turnLimit then
        scenarioTurn = turnLimit
    end

    local finisher = findFinisherSpec("cloudstriker_ranged")
    if not finisher then
        return nil, "cloudstriker_finisher_missing"
    end

    local rng = makeRng(seed + 9173)
    local layout = chooseRichContractLayout(seed, rng, "support_under_real_red_pressure")
    if type(layout.supportThreat) ~= "table" then
        return nil, "support_threat_layout_missing"
    end

    local state = composeSupportPressureState(finisher, layout, turnLimit, scenarioTurn)
    local finisherStagingCell = layout.finisherStaging or { row = layout.attack.row + 1, col = layout.attack.col }
    local requiredCells = cloneCells(layout.requiredCells)
    if #requiredCells == 0 then
        requiredCells = {
            { row = layout.supportKey.row, col = layout.supportKey.col },
            { row = layout.attack.row, col = layout.attack.col }
        }
    end
    local criticalBlueUnitIds = cloneIdList(layout.criticalBlueUnitIds)
    if #criticalBlueUnitIds == 0 then
        criticalBlueUnitIds = { "blue_finisher", "blue_a_support" }
    end
    local policyConfig = buildScenarioRedPolicyConfig(seed, requiredCells, criticalBlueUnitIds)

    local supportMove = moveExistsFor(state, "blue_a_support", layout.supportKey.row, layout.supportKey.col)
    local supportAttackAtStart = attackExistsFor(state, "blue_a_support", "neutral_rock")
    local falseDecoyAttack = attackExistsFor(state, "blue_finisher", "red_decoy")
    local finisherMoveDirectAtStart = moveExistsFor(state, "blue_finisher", layout.attack.row, layout.attack.col)
    if not supportMove or supportAttackAtStart or finisherMoveDirectAtStart or not inBounds(finisherStagingCell.row, finisherStagingCell.col) then
        return nil, "support_pressure_precondition_failed"
    end

    local redProbe = stateEngine.applyAction(state, { type = "end_turn" })
    local supportKilledOnPass, passPolicyRecord, passPolicyPlan, passPolicyErr =
        policyPlanKillsUnit(redProbe, policyConfig, "blue_a_support")
    if not supportKilledOnPass then
        return nil, passPolicyErr or "red_pressure_does_not_kill_support_on_pass"
    end

    local afterSupportMove = stateEngine.applyAction(state, supportMove)
    local supportRockAttack = attackExistsFor(afterSupportMove, "blue_a_support", "neutral_rock")
    if not supportRockAttack then
        return nil, "support_rock_attack_missing"
    end

    local afterRockClear = stateEngine.applyAction(afterSupportMove, supportRockAttack)
    local expectedWinningPrefix = {
        canonicalAction(supportMove),
        canonicalAction(supportRockAttack)
    }
    local turn2BlueStart, redTurnErr = advanceRedTurnWithPolicy(afterRockClear, expectedWinningPrefix, policyConfig)
    if not turn2BlueStart then
        return nil, redTurnErr or "red_policy_turn1_failed"
    end
    local supportAfterPressure = findUnitById(turn2BlueStart, "blue_a_support")
    if supportAfterPressure and (tonumber(supportAfterPressure.currentHp) or 0) > 0 then
        return nil, "red_pressure_not_executed_after_key"
    end

    local finisherStagingMove = moveExistsFor(turn2BlueStart, "blue_finisher", finisherStagingCell.row, finisherStagingCell.col)
    if not finisherStagingMove then
        return nil, "finisher_staging_move_missing"
    end
    local afterStaging = stateEngine.applyAction(turn2BlueStart, finisherStagingMove)
    local finisherAttackFromStaging = attackExistsFor(afterStaging, "blue_finisher", "red_commandant")
    if finisherAttackFromStaging then
        return nil, "finisher_staging_already_wins"
    end

    appendCanonical(expectedWinningPrefix, finisherStagingMove)
    local turn3BlueStart, redTurn2Err = advanceRedTurnWithPolicy(afterStaging, expectedWinningPrefix, policyConfig)
    if not turn3BlueStart then
        return nil, redTurn2Err or "red_policy_turn2_failed"
    end

    local commandantAttackBeforeFinisherMove = attackExistsFor(turn3BlueStart, "blue_finisher", "red_commandant")
    local finisherMove = moveExistsFor(turn3BlueStart, "blue_finisher", layout.attack.row, layout.attack.col)
    if not finisherMove then
        return nil, "finisher_required_cell_missing"
    end

    local afterFinisherMove = stateEngine.applyAction(turn3BlueStart, finisherMove)
    local commandantAttack = attackExistsFor(afterFinisherMove, "blue_finisher", "red_commandant")
    if not commandantAttack then
        return nil, "finisher_commandant_attack_missing"
    end

    local outcomeBeforeFinalAttack = stateEngine.evaluateOutcome(afterFinisherMove)
    local afterWin, winResult = stateEngine.applyAction(afterFinisherMove, commandantAttack)
    local outcome = stateEngine.evaluateOutcome(afterWin)
    if type(winResult) ~= "table" or winResult.ok ~= true or outcome.status ~= "blue_win" then
        return nil, "support_pressure_not_immediate_win"
    end
    appendCanonical(expectedWinningPrefix, finisherMove)
    appendCanonical(expectedWinningPrefix, commandantAttack)

    local actionConsequences = {
        compositionComposer.buildActionConsequence(
            "support_under_real_red_pressure",
            "support_pressure_setup_move",
            {
                seed = seed,
                actionIndex = 1,
                action = supportMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(state),
                afterStateHash = stateEngine.stateHash(afterSupportMove),
                evidence = {
                    attackBeforeMove = supportAttackAtStart ~= nil,
                    attackAfterMove = supportRockAttack ~= nil,
                    redKillsSupportIfBluePasses = supportKilledOnPass == true,
                    requiredSupportCell = formatCell(layout.supportKey.row, layout.supportKey.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "support_under_real_red_pressure",
            "support_rock_clear_attack",
            {
                seed = seed,
                actionIndex = 2,
                action = supportRockAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterSupportMove),
                afterStateHash = stateEngine.stateHash(afterRockClear),
                evidence = {
                    rockUnit = "neutral_rock",
                    rockAfterClear = findUnitById(afterRockClear, "neutral_rock") ~= nil,
                    requiredFinisherCell = formatCell(layout.attack.row, layout.attack.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "support_under_real_red_pressure",
            "finisher_staging_move",
            {
                seed = seed,
                actionIndex = 3,
                action = finisherStagingMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn2BlueStart),
                afterStateHash = stateEngine.stateHash(afterStaging),
                evidence = {
                    supportRemovedByPressure = supportAfterPressure == nil,
                    attackFromStaging = finisherAttackFromStaging ~= nil,
                    requiredFinisherCell = formatCell(layout.attack.row, layout.attack.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "support_under_real_red_pressure",
            "finisher_los_cell_move",
            {
                seed = seed,
                actionIndex = 4,
                action = finisherMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn3BlueStart),
                afterStateHash = stateEngine.stateHash(afterFinisherMove),
                evidence = {
                    commandantAttackBeforeLosCell = commandantAttackBeforeFinisherMove ~= nil,
                    commandantAttackAfterLosCell = commandantAttack ~= nil
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "support_under_real_red_pressure",
            "commandant_payoff_attack",
            {
                seed = seed,
                actionIndex = 5,
                action = commandantAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterFinisherMove),
                afterStateHash = stateEngine.stateHash(afterWin),
                evidence = {
                    outcomeBefore = outcomeBeforeFinalAttack and outcomeBeforeFinalAttack.status or "unknown",
                    outcomeAfter = outcome and outcome.status or "unknown"
                }
            }
        )
    }
    local compositionalContract, compositionErr = compositionComposer.buildContract(
        "support_under_real_red_pressure",
        expectedWinningPrefix,
        actionConsequences,
        { seed = seed }
    )
    if not compositionalContract then
        return nil, type(compositionErr) == "string" and compositionErr or "support_pressure_contract_build_failed"
    end
    local compositionOk = compositionComposer.validateContract(compositionalContract)
    if not compositionOk then
        return nil, "support_pressure_contract_validation_failed"
    end

    local candidate = {
        seed = seed,
        finisher = finisher,
        scenarioState = state,
        contractPattern = "support_under_real_red_pressure",
        microInteractions = {
            "SUPPORT_CELL_GAIN",
            "RED_ATTACKS_SUPPORT",
            "ROCK_AS_LOCK",
            "LOS_OPEN_RANGED",
            "FINISHER_CELL_GAIN",
            "WRONG_TARGET_TEMPO_LOSS"
        },
        commandantCellText = formatCell(layout.commandant.row, layout.commandant.col),
        attackCellText = formatCell(layout.attack.row, layout.attack.col),
        startCellText = formatCell(layout.finisherStart.row, layout.finisherStart.col),
        decoyCellText = layout.decoy and formatCell(layout.decoy.row, layout.decoy.col) or "",
        rockCellText = formatCell(layout.rock.row, layout.rock.col),
        supportStartCellText = formatCell(layout.supportStart.row, layout.supportStart.col),
        supportKeyCellText = formatCell(layout.supportKey.row, layout.supportKey.col),
        supportThreatCellText = formatCell(layout.supportThreat.row, layout.supportThreat.col),
        expectedWinningPrefix = expectedWinningPrefix,
        preferredFalseLine = {
            { type = "end_turn" }
        },
        scenarioRedPolicy = policyConfig,
        compositionalContract = compositionalContract,
        actionConsequences = actionConsequences,
        contractEvidence = {
            layoutSpecId = layout.layoutSpecId,
            layoutSpecVersion = layout.layoutSpecVersion,
            layoutConstraintVersion = layout.layoutConstraintVersion,
            supportMustReposition = supportAttackAtStart == nil,
            rockBlocksFinisherShotBeforeClear = true,
            actionConsequences = actionConsequences,
            falseTargetAvailable = falseDecoyAttack ~= nil,
            redSupportThreatCanKillBeforeSetup = supportKilledOnPass == true,
            redSupportThreatPlan = passPolicyPlan,
            redSupportThreatPolicyRecord = passPolicyRecord,
            requiredSupportCell = formatCell(layout.supportKey.row, layout.supportKey.col),
            requiredFinisherCell = formatCell(layout.attack.row, layout.attack.col),
            supportThreatCell = formatCell(layout.supportThreat.row, layout.supportThreat.col),
            rockCell = formatCell(layout.rock.row, layout.rock.col),
            shortcutBlockerCell = formatCell(layout.commandant.row + 1, layout.commandant.col),
            commandantCell = formatCell(layout.commandant.row, layout.commandant.col)
        }
    }
    candidate.tacticalFingerprint = buildFingerprint(candidate)
    return candidate
end

local function composeInterceptorArtilleryCandidateFromSeed(seed, opts)
    local turnLimit = normalizeTurnLimit(opts)
    local scenarioTurn = tonumber(opts and opts.scenarioTurn) or DEFAULT_SCENARIO_TURN
    if scenarioTurn < 1 then
        scenarioTurn = 1
    end
    if scenarioTurn > turnLimit then
        scenarioTurn = turnLimit
    end

    local finisher = findFinisherSpec("artillery_ranged")
    if not finisher then
        return nil, "artillery_finisher_missing"
    end

    local layout, layoutErr = interceptorArtilleryLayout()
    if not layout then
        return nil, type(layoutErr) == "string" and layoutErr or "interceptor_artillery_layout_invalid"
    end
    local state = composeInterceptorArtilleryState(finisher, layout, turnLimit, scenarioTurn)
    local requiredCells = cloneCells(layout.requiredCells)
    if #requiredCells == 0 then
        requiredCells = {
            { row = layout.supportKey.row, col = layout.supportKey.col },
            { row = layout.artilleryFinal.row, col = layout.artilleryFinal.col }
        }
    end
    local criticalBlueUnitIds = cloneIdList(layout.criticalBlueUnitIds)
    if #criticalBlueUnitIds == 0 then
        criticalBlueUnitIds = { "blue_finisher", "blue_a_support" }
    end
    local policyConfig = buildScenarioRedPolicyConfig(seed, requiredCells, criticalBlueUnitIds)

    local supportMove = moveExistsFor(state, "blue_a_support", layout.supportKey.row, layout.supportKey.col)
    local supportAttackAtStart = attackExistsFor(state, "blue_a_support", "red_interceptor")
    local finisherStagingAtStart = moveExistsFor(state, "blue_finisher", layout.artilleryStaging.row, layout.artilleryStaging.col)
    local finisherFinalAtStart = moveExistsFor(state, "blue_finisher", layout.artilleryFinal.row, layout.artilleryFinal.col)
    if not supportMove or supportAttackAtStart or finisherFinalAtStart then
        return nil, "interceptor_artillery_precondition_failed"
    end

    local redProbe = stateEngine.applyAction(state, { type = "end_turn" })
    local finisherKilledOnPass, passPolicyRecord, passPolicyPlan, passPolicyErr =
        policyPlanKillsUnit(redProbe, policyConfig, "blue_finisher")
    if not finisherKilledOnPass then
        return nil, passPolicyErr or "red_interceptor_does_not_kill_finisher_on_pass"
    end

    local afterSupportMove = stateEngine.applyAction(state, supportMove)
    local supportInterceptorAttack = attackExistsFor(afterSupportMove, "blue_a_support", "red_interceptor")
    if not supportInterceptorAttack then
        return nil, "support_interceptor_attack_missing"
    end

    local afterInterceptorClear = stateEngine.applyAction(afterSupportMove, supportInterceptorAttack)
    if findUnitById(afterInterceptorClear, "red_interceptor") then
        return nil, "interceptor_not_removed"
    end
    local expectedWinningPrefix = {
        canonicalAction(supportMove),
        canonicalAction(supportInterceptorAttack)
    }
    local turn2BlueStart, redTurnErr = advanceRedTurnWithPolicy(afterInterceptorClear, expectedWinningPrefix, policyConfig)
    if not turn2BlueStart then
        return nil, redTurnErr or "red_policy_turn1_failed"
    end
    if not findUnitById(turn2BlueStart, "blue_finisher") then
        return nil, "finisher_removed_after_interceptor_clear"
    end

    local artilleryStagingMove = moveExistsFor(turn2BlueStart, "blue_finisher", layout.artilleryStaging.row, layout.artilleryStaging.col)
    if not artilleryStagingMove then
        return nil, "artillery_staging_move_missing"
    end
    local afterStaging = stateEngine.applyAction(turn2BlueStart, artilleryStagingMove)
    local artilleryAttackFromStaging = attackExistsFor(afterStaging, "blue_finisher", "red_commandant")
    if artilleryAttackFromStaging then
        return nil, "artillery_staging_already_wins"
    end

    appendCanonical(expectedWinningPrefix, artilleryStagingMove)
    local turn3BlueStart, redTurn2Err = advanceRedTurnWithPolicy(afterStaging, expectedWinningPrefix, policyConfig)
    if not turn3BlueStart then
        return nil, redTurn2Err or "red_policy_turn2_failed"
    end

    local commandantAttackBeforeFinalCell = attackExistsFor(turn3BlueStart, "blue_finisher", "red_commandant")
    local artilleryFinalMove = moveExistsFor(turn3BlueStart, "blue_finisher", layout.artilleryFinal.row, layout.artilleryFinal.col)
    if not artilleryFinalMove then
        return nil, "artillery_final_cell_missing"
    end
    local afterFinalMove = stateEngine.applyAction(turn3BlueStart, artilleryFinalMove)
    local commandantAttack = attackExistsFor(afterFinalMove, "blue_finisher", "red_commandant")
    if not commandantAttack then
        return nil, "artillery_commandant_attack_missing"
    end

    local outcomeBeforeFinalAttack = stateEngine.evaluateOutcome(afterFinalMove)
    local afterWin, winResult = stateEngine.applyAction(afterFinalMove, commandantAttack)
    local outcome = stateEngine.evaluateOutcome(afterWin)
    if type(winResult) ~= "table" or winResult.ok ~= true or outcome.status ~= "blue_win" then
        return nil, "interceptor_artillery_not_immediate_win"
    end
    appendCanonical(expectedWinningPrefix, artilleryFinalMove)
    appendCanonical(expectedWinningPrefix, commandantAttack)

    local profileId = "support_intercepts_finisher_threat_artillery_finish"
    local actionConsequences = {
        compositionComposer.buildActionConsequence(
            profileId,
            "support_interceptor_setup_move",
            {
                seed = seed,
                actionIndex = 1,
                action = supportMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(state),
                afterStateHash = stateEngine.stateHash(afterSupportMove),
                evidence = {
                    attackBeforeMove = supportAttackAtStart ~= nil,
                    attackAfterMove = supportInterceptorAttack ~= nil,
                    redKillsFinisherIfBluePasses = finisherKilledOnPass == true,
                    requiredSupportCell = formatCell(layout.supportKey.row, layout.supportKey.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            profileId,
            "support_interceptor_clear_attack",
            {
                seed = seed,
                actionIndex = 2,
                action = supportInterceptorAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterSupportMove),
                afterStateHash = stateEngine.stateHash(afterInterceptorClear),
                evidence = {
                    interceptorUnit = "red_interceptor",
                    interceptorAfterClear = findUnitById(afterInterceptorClear, "red_interceptor") ~= nil,
                    redKillsFinisherIfIgnored = finisherKilledOnPass == true
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            profileId,
            "artillery_staging_move",
            {
                seed = seed,
                actionIndex = 3,
                action = artilleryStagingMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn2BlueStart),
                afterStateHash = stateEngine.stateHash(afterStaging),
                evidence = {
                    finalCellAtStart = finisherFinalAtStart ~= nil,
                    stagingAtStart = finisherStagingAtStart ~= nil,
                    attackFromStaging = artilleryAttackFromStaging ~= nil
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            profileId,
            "artillery_final_cell_move",
            {
                seed = seed,
                actionIndex = 4,
                action = artilleryFinalMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn3BlueStart),
                afterStateHash = stateEngine.stateHash(afterFinalMove),
                evidence = {
                    commandantAttackBeforeFinalCell = commandantAttackBeforeFinalCell ~= nil,
                    commandantAttackAfterFinalCell = commandantAttack ~= nil
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            profileId,
            "commandant_payoff_attack",
            {
                seed = seed,
                actionIndex = 5,
                action = commandantAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterFinalMove),
                afterStateHash = stateEngine.stateHash(afterWin),
                evidence = {
                    outcomeBefore = outcomeBeforeFinalAttack and outcomeBeforeFinalAttack.status or "unknown",
                    outcomeAfter = outcome and outcome.status or "unknown"
                }
            }
        )
    }
    local compositionalContract, compositionErr = compositionComposer.buildContract(
        profileId,
        expectedWinningPrefix,
        actionConsequences,
        { seed = seed }
    )
    if not compositionalContract then
        return nil, type(compositionErr) == "string" and compositionErr or "interceptor_artillery_contract_build_failed"
    end
    local compositionOk = compositionComposer.validateContract(compositionalContract)
    if not compositionOk then
        return nil, "interceptor_artillery_contract_validation_failed"
    end

    local candidate = {
        seed = seed,
        finisher = finisher,
        scenarioState = state,
        contractPattern = profileId,
        microInteractions = {
            "SUPPORT_CELL_GAIN",
            "RED_ATTACKS_FINISHER",
            "FINISHER_CELL_GAIN",
            "WRONG_TARGET_TEMPO_LOSS",
            "ORDER_DEPENDENCY",
            "HP_EXACT_WINDOW"
        },
        commandantCellText = formatCell(layout.commandant.row, layout.commandant.col),
        attackCellText = formatCell(layout.artilleryFinal.row, layout.artilleryFinal.col),
        startCellText = formatCell(layout.finisherStart.row, layout.finisherStart.col),
        decoyCellText = layout.decoy and formatCell(layout.decoy.row, layout.decoy.col) or "",
        supportStartCellText = formatCell(layout.supportStart.row, layout.supportStart.col),
        supportKeyCellText = formatCell(layout.supportKey.row, layout.supportKey.col),
        interceptorCellText = formatCell(layout.interceptor.row, layout.interceptor.col),
        expectedWinningPrefix = expectedWinningPrefix,
        preferredFalseLine = {
            { type = "end_turn" }
        },
        scenarioRedPolicy = policyConfig,
        compositionalContract = compositionalContract,
        actionConsequences = actionConsequences,
        contractEvidence = {
            layoutSpecId = layout.layoutSpecId,
            layoutSpecVersion = layout.layoutSpecVersion,
            layoutConstraintVersion = layout.layoutConstraintVersion,
            supportMustReposition = supportAttackAtStart == nil,
            interceptorMustBeResolved = true,
            pressureCanBeAttackedAtStart = supportAttackAtStart ~= nil,
            actionConsequences = actionConsequences,
            requiredSupportCell = formatCell(layout.supportKey.row, layout.supportKey.col),
            requiredFinisherCell = formatCell(layout.artilleryFinal.row, layout.artilleryFinal.col),
            stagingCell = formatCell(layout.artilleryStaging.row, layout.artilleryStaging.col),
            interceptorCell = formatCell(layout.interceptor.row, layout.interceptor.col),
            commandantCell = formatCell(layout.commandant.row, layout.commandant.col),
            redFinisherInterceptorCanKillBeforeSetup = finisherKilledOnPass == true,
            redFinisherInterceptorPlan = passPolicyPlan,
            redFinisherInterceptorPolicyRecord = passPolicyRecord,
            redPressureUnit = "red_interceptor",
            finisherInterceptorUnit = "red_interceptor",
            contactBlockerAlsoPressure = false
        }
    }
    candidate.tacticalFingerprint = buildFingerprint(candidate)
    return candidate
end

local function composeDualRockLockCandidateFromSeed(seed, opts)
    local turnLimit = normalizeTurnLimit(opts)
    local scenarioTurn = tonumber(opts and opts.scenarioTurn) or DEFAULT_SCENARIO_TURN
    if scenarioTurn < 1 then
        scenarioTurn = 1
    end
    if scenarioTurn > turnLimit then
        scenarioTurn = turnLimit
    end

    local finisher = findFinisherSpec("cloudstriker_ranged")
    if not finisher then
        return nil, "cloudstriker_finisher_missing"
    end

    local layout, layoutErr = dualRockLockLayout()
    if not layout then
        return nil, type(layoutErr) == "string" and layoutErr or "dual_rock_lock_layout_invalid"
    end
    local state = composeDualRockLockState(finisher, layout, turnLimit, scenarioTurn)
    local requiredCells = cloneCells(layout.requiredCells)
    if #requiredCells == 0 then
        requiredCells = {
            { row = layout.supportLowerKey.row, col = layout.supportLowerKey.col },
            { row = layout.supportUpperKey.row, col = layout.supportUpperKey.col },
            { row = layout.attack.row, col = layout.attack.col }
        }
    end
    local criticalBlueUnitIds = cloneIdList(layout.criticalBlueUnitIds)
    if #criticalBlueUnitIds == 0 then
        criticalBlueUnitIds = { "blue_finisher", "blue_a_support" }
    end
    local policyConfig = buildScenarioRedPolicyConfig(seed, requiredCells, criticalBlueUnitIds)

    local lowerSetupMove = moveExistsFor(state, "blue_a_support", layout.supportLowerKey.row, layout.supportLowerKey.col)
    local lowerAttackAtStart = attackExistsFor(state, "blue_a_support", "neutral_lower_rock")
    local upperAttackAtStart = attackExistsFor(state, "blue_a_support", "neutral_upper_rock")
    local finisherFinalMoveAtStart = moveExistsFor(state, "blue_finisher", layout.attack.row, layout.attack.col)
    if not lowerSetupMove or lowerAttackAtStart or upperAttackAtStart then
        return nil, "dual_rock_lock_precondition_failed"
    end

    local afterLowerSetup = stateEngine.applyAction(state, lowerSetupMove)
    local lowerRockAttack = attackExistsFor(afterLowerSetup, "blue_a_support", "neutral_lower_rock")
    if not lowerRockAttack then
        return nil, "dual_lower_rock_attack_missing"
    end
    local afterLowerClear = stateEngine.applyAction(afterLowerSetup, lowerRockAttack)
    if findUnitById(afterLowerClear, "neutral_lower_rock") == nil and findUnitById(afterLowerClear, "neutral_upper_rock") == nil then
        return nil, "dual_locks_removed_by_single_attack"
    end
    if findUnitById(afterLowerClear, "neutral_lower_rock") then
        return nil, "dual_lower_rock_not_removed"
    end
    if not findUnitById(afterLowerClear, "neutral_upper_rock") then
        return nil, "dual_upper_rock_removed_too_early"
    end

    local expectedWinningPrefix = {
        canonicalAction(lowerSetupMove),
        canonicalAction(lowerRockAttack)
    }
    local turn2BlueStart, redTurnErr = advanceRedTurnWithPolicy(afterLowerClear, expectedWinningPrefix, policyConfig)
    if not turn2BlueStart then
        return nil, redTurnErr or "dual_red_policy_turn1_failed"
    end

    local upperSetupMove = moveExistsFor(turn2BlueStart, "blue_a_support", layout.supportUpperKey.row, layout.supportUpperKey.col)
    if not upperSetupMove then
        return nil, "dual_upper_setup_move_missing"
    end
    local afterUpperSetup = stateEngine.applyAction(turn2BlueStart, upperSetupMove)
    local upperRockAttack = attackExistsFor(afterUpperSetup, "blue_a_support", "neutral_upper_rock")
    if not upperRockAttack then
        return nil, "dual_upper_rock_attack_missing"
    end
    local afterUpperClear = stateEngine.applyAction(afterUpperSetup, upperRockAttack)
    if findUnitById(afterUpperClear, "neutral_upper_rock") then
        return nil, "dual_upper_rock_not_removed"
    end
    if attackExistsFor(afterUpperClear, "blue_finisher", "red_commandant") then
        return nil, "dual_finisher_already_attacks_before_final_cell"
    end

    appendCanonical(expectedWinningPrefix, upperSetupMove)
    appendCanonical(expectedWinningPrefix, upperRockAttack)
    local turn3BlueStart, redTurn2Err = advanceRedTurnWithPolicy(afterUpperClear, expectedWinningPrefix, policyConfig)
    if not turn3BlueStart then
        return nil, redTurn2Err or "dual_red_policy_turn2_failed"
    end

    local commandantAttackBeforeFinalCell = attackExistsFor(turn3BlueStart, "blue_finisher", "red_commandant")
    local finisherFinalMove = moveExistsFor(turn3BlueStart, "blue_finisher", layout.attack.row, layout.attack.col)
    if not finisherFinalMove then
        return nil, "dual_finisher_final_cell_missing"
    end
    local afterFinalMove = stateEngine.applyAction(turn3BlueStart, finisherFinalMove)
    local commandantAttack = attackExistsFor(afterFinalMove, "blue_finisher", "red_commandant")
    if not commandantAttack then
        return nil, "dual_commandant_attack_missing"
    end

    local outcomeBeforeFinalAttack = stateEngine.evaluateOutcome(afterFinalMove)
    local afterWin, winResult = stateEngine.applyAction(afterFinalMove, commandantAttack)
    local outcome = stateEngine.evaluateOutcome(afterWin)
    if type(winResult) ~= "table" or winResult.ok ~= true or outcome.status ~= "blue_win" then
        return nil, "dual_rock_lock_not_immediate_win"
    end
    appendCanonical(expectedWinningPrefix, finisherFinalMove)
    appendCanonical(expectedWinningPrefix, commandantAttack)

    local profileId = "dual_rock_lock_ranged_finish"
    local actionConsequences = {
        compositionComposer.buildActionConsequence(
            profileId,
            "support_lower_lock_setup_move",
            {
                seed = seed,
                actionIndex = 1,
                action = lowerSetupMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(state),
                afterStateHash = stateEngine.stateHash(afterLowerSetup),
                evidence = {
                    attackBeforeMove = lowerAttackAtStart ~= nil,
                    attackAfterMove = lowerRockAttack ~= nil,
                    lowerRockCell = formatCell(layout.lowerRock.row, layout.lowerRock.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            profileId,
            "support_lower_rock_clear_attack",
            {
                seed = seed,
                actionIndex = 2,
                action = lowerRockAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterLowerSetup),
                afterStateHash = stateEngine.stateHash(afterLowerClear),
                evidence = {
                    lowerRockAfterClear = findUnitById(afterLowerClear, "neutral_lower_rock") ~= nil,
                    upperRockStillPresent = findUnitById(afterLowerClear, "neutral_upper_rock") ~= nil
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            profileId,
            "support_upper_lock_setup_move",
            {
                seed = seed,
                actionIndex = 3,
                action = upperSetupMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn2BlueStart),
                afterStateHash = stateEngine.stateHash(afterUpperSetup),
                evidence = {
                    upperRockStillPresent = findUnitById(turn2BlueStart, "neutral_upper_rock") ~= nil,
                    upperAttackAfterMove = upperRockAttack ~= nil,
                    supportUpperCell = formatCell(layout.supportUpperKey.row, layout.supportUpperKey.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            profileId,
            "support_upper_rock_clear_attack",
            {
                seed = seed,
                actionIndex = 4,
                action = upperRockAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterUpperSetup),
                afterStateHash = stateEngine.stateHash(afterUpperClear),
                evidence = {
                    upperRockAfterClear = findUnitById(afterUpperClear, "neutral_upper_rock") ~= nil,
                    commandantAttackBeforeUpperClear = attackExistsFor(afterUpperSetup, "blue_finisher", "red_commandant") ~= nil,
                    commandantAttackAfterUpperClear = attackExistsFor(afterUpperClear, "blue_finisher", "red_commandant") ~= nil
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            profileId,
            "finisher_dual_lock_cell_move",
            {
                seed = seed,
                actionIndex = 5,
                action = finisherFinalMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn3BlueStart),
                afterStateHash = stateEngine.stateHash(afterFinalMove),
                evidence = {
                    finalCellAtStart = finisherFinalMoveAtStart ~= nil,
                    commandantAttackBeforeFinalCell = commandantAttackBeforeFinalCell ~= nil,
                    commandantAttackAfterFinalCell = commandantAttack ~= nil
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            profileId,
            "commandant_payoff_attack",
            {
                seed = seed,
                actionIndex = 6,
                action = commandantAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterFinalMove),
                afterStateHash = stateEngine.stateHash(afterWin),
                evidence = {
                    outcomeBefore = outcomeBeforeFinalAttack and outcomeBeforeFinalAttack.status or "unknown",
                    outcomeAfter = outcome and outcome.status or "unknown"
                }
            }
        )
    }
    local compositionalContract, compositionErr = compositionComposer.buildContract(
        profileId,
        expectedWinningPrefix,
        actionConsequences,
        { seed = seed }
    )
    if not compositionalContract then
        return nil, type(compositionErr) == "string" and compositionErr or "dual_rock_lock_contract_build_failed"
    end
    local compositionOk = compositionComposer.validateContract(compositionalContract)
    if not compositionOk then
        return nil, "dual_rock_lock_contract_validation_failed"
    end

    local candidate = {
        seed = seed,
        finisher = finisher,
        scenarioState = state,
        contractPattern = profileId,
        microInteractions = {
            "SUPPORT_CELL_GAIN",
            "ROCK_AS_LOCK",
            "ORDER_DEPENDENCY",
            "LOS_OPEN_RANGED",
            "FINISHER_CELL_GAIN",
            "WRONG_TARGET_TEMPO_LOSS",
            "HP_EXACT_WINDOW"
        },
        commandantCellText = formatCell(layout.commandant.row, layout.commandant.col),
        attackCellText = formatCell(layout.attack.row, layout.attack.col),
        startCellText = formatCell(layout.finisherStart.row, layout.finisherStart.col),
        decoyCellText = "dual_rock_lock_chain",
        rockCellText = formatCell(layout.lowerRock.row, layout.lowerRock.col) .. "+" .. formatCell(layout.upperRock.row, layout.upperRock.col),
        supportStartCellText = formatCell(layout.supportStart.row, layout.supportStart.col),
        supportKeyCellText = formatCell(layout.supportLowerKey.row, layout.supportLowerKey.col),
        supportUpperKeyCellText = formatCell(layout.supportUpperKey.row, layout.supportUpperKey.col),
        expectedWinningPrefix = expectedWinningPrefix,
        preferredFalseLine = {
            { type = "end_turn" }
        },
        scenarioRedPolicy = policyConfig,
        compositionalContract = compositionalContract,
        actionConsequences = actionConsequences,
        contractEvidence = {
            layoutSpecId = layout.layoutSpecId,
            layoutSpecVersion = layout.layoutSpecVersion,
            layoutConstraintVersion = layout.layoutConstraintVersion,
            supportMustReposition = lowerAttackAtStart == nil,
            dualRockLockChain = true,
            lowerRockMustBeResolved = true,
            upperRockMustBeResolved = true,
            actionConsequences = actionConsequences,
            requiredSupportCell = formatCell(layout.supportLowerKey.row, layout.supportLowerKey.col),
            requiredSecondSupportCell = formatCell(layout.supportUpperKey.row, layout.supportUpperKey.col),
            requiredFinisherCell = formatCell(layout.attack.row, layout.attack.col),
            lowerRockCell = formatCell(layout.lowerRock.row, layout.lowerRock.col),
            upperRockCell = formatCell(layout.upperRock.row, layout.upperRock.col),
            commandantCell = formatCell(layout.commandant.row, layout.commandant.col),
            pressureCanBeAttackedAtStart = false,
            contactBlockerAlsoPressure = false
        }
    }
    candidate.tacticalFingerprint = buildFingerprint(candidate)
    return candidate
end

local function composeCrusherContactCandidateFromSeed(seed, opts)
    local turnLimit = normalizeTurnLimit(opts)
    local scenarioTurn = tonumber(opts and opts.scenarioTurn) or DEFAULT_SCENARIO_TURN
    if scenarioTurn < 1 then
        scenarioTurn = 1
    end
    if scenarioTurn > turnLimit then
        scenarioTurn = turnLimit
    end

    local finisher = findFinisherSpec("crusher_melee")
    if not finisher then
        return nil, "crusher_finisher_missing"
    end

    local layout, layoutErr = crusherContactLayout()
    if not layout then
        return nil, type(layoutErr) == "string" and layoutErr or "crusher_contact_layout_invalid"
    end
    local state = composeCrusherContactState(finisher, layout, turnLimit, scenarioTurn)
    local requiredCells = cloneCells(layout.requiredCells)
    if #requiredCells == 0 then
        requiredCells = {
            { row = layout.supportKey.row, col = layout.supportKey.col },
            { row = layout.contact.row, col = layout.contact.col }
        }
    end
    local criticalBlueUnitIds = cloneIdList(layout.criticalBlueUnitIds)
    if #criticalBlueUnitIds == 0 then
        criticalBlueUnitIds = { "blue_finisher", "blue_a_support" }
    end
    local policyConfig = buildScenarioRedPolicyConfig(seed, requiredCells, criticalBlueUnitIds)

    local supportMove = moveExistsFor(state, "blue_a_support", layout.supportKey.row, layout.supportKey.col)
    local supportAttackAtStart = attackExistsFor(state, "blue_a_support", "red_contact_blocker")
    local falseDecoyAttack = attackExistsFor(state, "blue_finisher", "red_decoy")
    local directContactMoveAtStart = moveExistsFor(state, "blue_finisher", layout.contact.row, layout.contact.col)
    if not supportMove or supportAttackAtStart or directContactMoveAtStart then
        return nil, "crusher_contact_precondition_failed"
    end

    local afterSupportMove = stateEngine.applyAction(state, supportMove)
    local supportContactAttack = attackExistsFor(afterSupportMove, "blue_a_support", "red_contact_blocker")
    if not supportContactAttack then
        return nil, "support_contact_attack_missing"
    end

    local expectedWinningPrefix = {
        canonicalAction(supportMove),
        canonicalAction(supportContactAttack)
    }
    local afterContactClear = stateEngine.applyAction(afterSupportMove, supportContactAttack)
    local turn2BlueStart, redTurnErr = advanceRedTurnWithPolicy(afterContactClear, expectedWinningPrefix, policyConfig)
    if not turn2BlueStart then
        return nil, redTurnErr or "red_policy_turn1_failed"
    end

    local contactMoveBeforeStaging = moveExistsFor(turn2BlueStart, "blue_finisher", layout.contact.row, layout.contact.col)
    local stagingCell = layout.finisherStaging or { row = 5, col = layout.contact.col }
    local stagingMove = moveExistsFor(turn2BlueStart, "blue_finisher", stagingCell.row, stagingCell.col)
    if not stagingMove then
        return nil, "crusher_staging_move_missing"
    end
    local afterStaging = stateEngine.applyAction(turn2BlueStart, stagingMove)
    if attackExistsFor(afterStaging, "blue_finisher", "red_commandant") then
        return nil, "crusher_staging_already_wins"
    end

    appendCanonical(expectedWinningPrefix, stagingMove)
    local turn3BlueStart, redTurn2Err = advanceRedTurnWithPolicy(afterStaging, expectedWinningPrefix, policyConfig)
    if not turn3BlueStart then
        return nil, redTurn2Err or "red_policy_turn2_failed"
    end

    local contactMove = moveExistsFor(turn3BlueStart, "blue_finisher", layout.contact.row, layout.contact.col)
    if not contactMove then
        return nil, "crusher_contact_move_missing"
    end
    local commandantAttackBeforeContact = attackExistsFor(turn3BlueStart, "blue_finisher", "red_commandant")
    local afterContact = stateEngine.applyAction(turn3BlueStart, contactMove)
    local commandantAttack = attackExistsFor(afterContact, "blue_finisher", "red_commandant")
    if not commandantAttack then
        return nil, "crusher_commandant_attack_missing"
    end
    local outcomeBeforeFinalAttack = stateEngine.evaluateOutcome(afterContact)
    local afterWin, winResult = stateEngine.applyAction(afterContact, commandantAttack)
    local outcome = stateEngine.evaluateOutcome(afterWin)
    if type(winResult) ~= "table" or winResult.ok ~= true or outcome.status ~= "blue_win" then
        return nil, "crusher_contact_not_immediate_win"
    end
    appendCanonical(expectedWinningPrefix, contactMove)
    appendCanonical(expectedWinningPrefix, commandantAttack)

    local actionConsequences = {
        compositionComposer.buildActionConsequence(
            "crusher_contact_breach",
            "support_contact_setup_move",
            {
                seed = seed,
                actionIndex = 1,
                action = supportMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(state),
                afterStateHash = stateEngine.stateHash(afterSupportMove),
                evidence = {
                    attackBeforeMove = supportAttackAtStart ~= nil,
                    attackAfterMove = supportContactAttack ~= nil,
                    requiredSupportCell = formatCell(layout.supportKey.row, layout.supportKey.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "crusher_contact_breach",
            "support_blocker_clear_attack",
            {
                seed = seed,
                actionIndex = 2,
                action = supportContactAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterSupportMove),
                afterStateHash = stateEngine.stateHash(afterContactClear),
                evidence = {
                    contactBlockerUnit = "red_contact_blocker",
                    blockerAfterClear = findUnitById(afterContactClear, "red_contact_blocker") ~= nil,
                    requiredFinisherCell = formatCell(layout.contact.row, layout.contact.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "crusher_contact_breach",
            "finisher_staging_move",
            {
                seed = seed,
                actionIndex = 3,
                action = stagingMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn2BlueStart),
                afterStateHash = stateEngine.stateHash(afterStaging),
                evidence = {
                    contactMoveBeforeStaging = contactMoveBeforeStaging ~= nil,
                    contactMoveAfterStagingAndRed = contactMove ~= nil,
                    requiredFinisherCell = formatCell(layout.contact.row, layout.contact.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "crusher_contact_breach",
            "crusher_contact_move",
            {
                seed = seed,
                actionIndex = 4,
                action = contactMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn3BlueStart),
                afterStateHash = stateEngine.stateHash(afterContact),
                evidence = {
                    commandantAttackBeforeContact = commandantAttackBeforeContact ~= nil,
                    commandantAttackAfterContact = commandantAttack ~= nil
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "crusher_contact_breach",
            "commandant_payoff_attack",
            {
                seed = seed,
                actionIndex = 5,
                action = commandantAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterContact),
                afterStateHash = stateEngine.stateHash(afterWin),
                evidence = {
                    outcomeBefore = outcomeBeforeFinalAttack and outcomeBeforeFinalAttack.status or "unknown",
                    outcomeAfter = outcome and outcome.status or "unknown"
                }
            }
        )
    }
    local compositionalContract, compositionErr = compositionComposer.buildContract(
        "crusher_contact_breach",
        expectedWinningPrefix,
        actionConsequences,
        { seed = seed }
    )
    if not compositionalContract then
        return nil, type(compositionErr) == "string" and compositionErr or "crusher_contact_contract_build_failed"
    end
    local compositionOk = compositionComposer.validateContract(compositionalContract)
    if not compositionOk then
        return nil, "crusher_contact_contract_validation_failed"
    end

    local candidate = {
        seed = seed,
        finisher = finisher,
        scenarioState = state,
        contractPattern = "crusher_contact_breach",
        microInteractions = {
            "SUPPORT_CELL_GAIN",
            "FINISHER_CELL_GAIN",
            "WRONG_TARGET_TEMPO_LOSS",
            "ORDER_DEPENDENCY",
            "HP_EXACT_WINDOW"
        },
        commandantCellText = formatCell(layout.commandant.row, layout.commandant.col),
        attackCellText = formatCell(layout.contact.row, layout.contact.col),
        startCellText = formatCell(layout.finisherStart.row, layout.finisherStart.col),
        decoyCellText = formatCell(layout.pressureDecoy.row, layout.pressureDecoy.col),
        supportStartCellText = formatCell(layout.supportStart.row, layout.supportStart.col),
        supportKeyCellText = formatCell(layout.supportKey.row, layout.supportKey.col),
        expectedWinningPrefix = expectedWinningPrefix,
        preferredFalseLine = {
            { type = "end_turn" }
        },
        scenarioRedPolicy = policyConfig,
        compositionalContract = compositionalContract,
        actionConsequences = actionConsequences,
        contractEvidence = {
            layoutSpecId = layout.layoutSpecId,
            layoutSpecVersion = layout.layoutSpecVersion,
            layoutConstraintVersion = layout.layoutConstraintVersion,
            supportMustReposition = supportAttackAtStart == nil,
            contactBlockerMustBeResolved = true,
            actionConsequences = actionConsequences,
            falseTargetAvailable = falseDecoyAttack ~= nil,
            requiredSupportCell = formatCell(layout.supportKey.row, layout.supportKey.col),
            requiredFinisherCell = formatCell(layout.contact.row, layout.contact.col),
            contactBlockerCell = formatCell(layout.contactBlocker.row, layout.contactBlocker.col),
            commandantCell = formatCell(layout.commandant.row, layout.commandant.col)
        }
    }
    candidate.tacticalFingerprint = buildFingerprint(candidate)
    return candidate
end

local function composeCompositeSupportPressureCrusherCandidateFromSeed(seed, opts)
    local turnLimit = normalizeTurnLimit(opts)
    local scenarioTurn = tonumber(opts and opts.scenarioTurn) or DEFAULT_SCENARIO_TURN
    if scenarioTurn < 1 then
        scenarioTurn = 1
    end
    if scenarioTurn > turnLimit then
        scenarioTurn = turnLimit
    end

    local finisher = findFinisherSpec("crusher_melee")
    if not finisher then
        return nil, "crusher_finisher_missing"
    end

    local layout, layoutErr = compositeSupportPressureCrusherLayout(opts)
    if not layout then
        return nil, type(layoutErr) == "string" and layoutErr or "composite_layout_invalid"
    end
    local state = composeCompositeSupportPressureCrusherState(finisher, layout, turnLimit, scenarioTurn)
    local requiredCells = cloneCells(layout.requiredCells)
    if #requiredCells == 0 then
        requiredCells = {
            { row = layout.supportKey.row, col = layout.supportKey.col },
            { row = layout.contact.row, col = layout.contact.col }
        }
    end
    local criticalBlueUnitIds = cloneIdList(layout.criticalBlueUnitIds)
    if #criticalBlueUnitIds == 0 then
        criticalBlueUnitIds = { "blue_finisher", "blue_a_support" }
    end
    local policyConfig = buildScenarioRedPolicyConfig(seed, requiredCells, criticalBlueUnitIds)

    local supportMove = moveExistsFor(state, "blue_a_support", layout.supportKey.row, layout.supportKey.col)
    local supportAttackAtStart = attackExistsFor(state, "blue_a_support", "red_contact_blocker")
    local directContactMoveAtStart = moveExistsFor(state, "blue_finisher", layout.contact.row, layout.contact.col)
    local pressureAttackAtStart = attackExistsFor(state, "blue_a_support", "red_support_threat")
    if not supportMove or supportAttackAtStart or directContactMoveAtStart or pressureAttackAtStart then
        return nil, "composite_precondition_failed"
    end

    local redProbe = stateEngine.applyAction(state, { type = "end_turn" })
    local supportKilledOnPass, passPolicyRecord, passPolicyPlan, passPolicyErr =
        policyPlanKillsUnit(redProbe, policyConfig, "blue_a_support")
    if not supportKilledOnPass then
        return nil, passPolicyErr or "composite_support_pressure_not_proven"
    end

    local afterSupportMove = stateEngine.applyAction(state, supportMove)
    local supportContactAttack = attackExistsFor(afterSupportMove, "blue_a_support", "red_contact_blocker")
    if not supportContactAttack then
        return nil, "support_contact_attack_missing"
    end

    local expectedWinningPrefix = {
        canonicalAction(supportMove),
        canonicalAction(supportContactAttack)
    }
    local afterContactClear = stateEngine.applyAction(afterSupportMove, supportContactAttack)
    local turn2BlueStart, redTurnErr = advanceRedTurnWithPolicy(afterContactClear, expectedWinningPrefix, policyConfig)
    if not turn2BlueStart then
        return nil, redTurnErr or "red_policy_turn1_failed"
    end

    local stagingCell = layout.finisherStaging or { row = 5, col = layout.contact.col }
    local stagingMove = moveExistsFor(turn2BlueStart, "blue_finisher", stagingCell.row, stagingCell.col)
    if not stagingMove then
        return nil, "crusher_staging_move_missing"
    end
    local afterStaging = stateEngine.applyAction(turn2BlueStart, stagingMove)
    if attackExistsFor(afterStaging, "blue_finisher", "red_commandant") then
        return nil, "crusher_staging_already_wins"
    end

    appendCanonical(expectedWinningPrefix, stagingMove)
    local turn3BlueStart, redTurn2Err = advanceRedTurnWithPolicy(afterStaging, expectedWinningPrefix, policyConfig)
    if not turn3BlueStart then
        return nil, redTurn2Err or "red_policy_turn2_failed"
    end

    local contactMove = moveExistsFor(turn3BlueStart, "blue_finisher", layout.contact.row, layout.contact.col)
    if not contactMove then
        return nil, "crusher_contact_move_missing"
    end
    local commandantAttackBeforeContact = attackExistsFor(turn3BlueStart, "blue_finisher", "red_commandant")
    local afterContact = stateEngine.applyAction(turn3BlueStart, contactMove)
    local commandantAttack = attackExistsFor(afterContact, "blue_finisher", "red_commandant")
    if not commandantAttack then
        return nil, "crusher_commandant_attack_missing"
    end
    local outcomeBeforeFinalAttack = stateEngine.evaluateOutcome(afterContact)
    local afterWin, winResult = stateEngine.applyAction(afterContact, commandantAttack)
    local outcome = stateEngine.evaluateOutcome(afterWin)
    if type(winResult) ~= "table" or winResult.ok ~= true or outcome.status ~= "blue_win" then
        return nil, "composite_not_immediate_win"
    end
    appendCanonical(expectedWinningPrefix, contactMove)
    appendCanonical(expectedWinningPrefix, commandantAttack)

    local actionConsequences = {
        compositionComposer.buildActionConsequence(
            "composite_support_pressure_crusher_contact",
            "support_setup_move",
            {
                seed = seed,
                actionIndex = 1,
                action = supportMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(state),
                afterStateHash = stateEngine.stateHash(afterSupportMove),
                attackBeforeMove = supportAttackAtStart ~= nil,
                attackAfterMove = supportContactAttack ~= nil,
                evidence = {
                    attackBeforeMove = supportAttackAtStart ~= nil,
                    attackAfterMove = supportContactAttack ~= nil,
                    redKillsSupportIfBluePasses = supportKilledOnPass == true
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "composite_support_pressure_crusher_contact",
            "support_blocker_clear_attack",
            {
                seed = seed,
                actionIndex = 2,
                action = supportContactAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterSupportMove),
                afterStateHash = stateEngine.stateHash(afterContactClear),
                evidence = {
                    contactBlockerUnit = "red_contact_blocker",
                    blockerAfterClear = findUnitById(afterContactClear, "red_contact_blocker") ~= nil,
                    requiredFinisherCell = formatCell(layout.contact.row, layout.contact.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "composite_support_pressure_crusher_contact",
            "finisher_staging_move",
            {
                seed = seed,
                actionIndex = 3,
                action = stagingMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn2BlueStart),
                afterStateHash = stateEngine.stateHash(afterStaging),
                evidence = {
                    contactMoveBeforeStaging = contactMoveBeforeStaging ~= nil,
                    contactMoveAfterStagingAndRed = contactMove ~= nil,
                    requiredFinisherCell = formatCell(layout.contact.row, layout.contact.col)
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "composite_support_pressure_crusher_contact",
            "crusher_contact_move",
            {
                seed = seed,
                actionIndex = 4,
                action = contactMove,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(turn3BlueStart),
                afterStateHash = stateEngine.stateHash(afterContact),
                evidence = {
                    commandantAttackBeforeContact = commandantAttackBeforeContact ~= nil,
                    commandantAttackAfterContact = commandantAttack ~= nil
                }
            }
        ),
        compositionComposer.buildActionConsequence(
            "composite_support_pressure_crusher_contact",
            "commandant_payoff_attack",
            {
                seed = seed,
                actionIndex = 5,
                action = commandantAttack,
                horizon = turnLimit,
                beforeStateHash = stateEngine.stateHash(afterContact),
                afterStateHash = stateEngine.stateHash(afterWin),
                evidence = {
                    outcomeBefore = outcomeBeforeFinalAttack and outcomeBeforeFinalAttack.status or "unknown",
                    outcomeAfter = outcome and outcome.status or "unknown"
                }
            }
        )
    }
    local compositionalContract, compositionErr = compositionComposer.buildContract(
        "composite_support_pressure_crusher_contact",
        expectedWinningPrefix,
        actionConsequences,
        { seed = seed }
    )
    if not compositionalContract then
        return nil, type(compositionErr) == "string" and compositionErr or "composite_contract_build_failed"
    end
    local compositionOk = compositionComposer.validateContract(compositionalContract)
    if not compositionOk then
        return nil, "composite_contract_validation_failed"
    end

    local candidate = {
        seed = seed,
        finisher = finisher,
        scenarioState = state,
        contractPattern = "composite_support_pressure_crusher_contact",
        microInteractions = {
            "SUPPORT_CELL_GAIN",
            "RED_ATTACKS_SUPPORT",
            "FINISHER_CELL_GAIN",
            "WRONG_TARGET_TEMPO_LOSS",
            "ORDER_DEPENDENCY",
            "HP_EXACT_WINDOW"
        },
        commandantCellText = formatCell(layout.commandant.row, layout.commandant.col),
        attackCellText = formatCell(layout.contact.row, layout.contact.col),
        startCellText = formatCell(layout.finisherStart.row, layout.finisherStart.col),
        decoyCellText = formatCell(layout.pressureStart.row, layout.pressureStart.col),
        supportStartCellText = formatCell(layout.supportStart.row, layout.supportStart.col),
        supportKeyCellText = formatCell(layout.supportKey.row, layout.supportKey.col),
        expectedWinningPrefix = expectedWinningPrefix,
        preferredFalseLine = {
            { type = "end_turn" }
        },
        scenarioRedPolicy = policyConfig,
        compositionalContract = compositionalContract,
        actionConsequences = actionConsequences,
        contractEvidence = {
            layoutSpecId = layout.layoutSpecId,
            layoutSpecVersion = layout.layoutSpecVersion,
            layoutConstraintVersion = layout.layoutConstraintVersion,
            layoutOffset = {
                rowOffset = tonumber(layout.rowOffset) or 0,
                colOffset = tonumber(layout.colOffset) or 0
            },
            supportMustReposition = supportAttackAtStart == nil,
            contactBlockerMustBeResolved = true,
            pressureCanBeAttackedAtStart = pressureAttackAtStart ~= nil,
            actionConsequences = actionConsequences,
            requiredSupportCell = formatCell(layout.supportKey.row, layout.supportKey.col),
            requiredFinisherCell = formatCell(layout.contact.row, layout.contact.col),
            contactBlockerCell = formatCell(layout.contactBlocker.row, layout.contactBlocker.col),
            pressureCell = formatCell(layout.pressureStart.row, layout.pressureStart.col),
            commandantCell = formatCell(layout.commandant.row, layout.commandant.col),
            compositeComponents = {
                "support_pressure",
                "crusher_contact_breach"
            },
            redSupportThreatCanKillBeforeSetup = true,
            redSupportThreatPlan = passPolicyPlan,
            redSupportThreatPolicyRecord = passPolicyRecord,
            redPressureUnit = "red_support_threat",
            contactBlockerUnit = "red_contact_blocker",
            contactBlockerAlsoPressure = false
        }
    }
    candidate.tacticalFingerprint = buildFingerprint(candidate)
    return candidate
end

local function composeCandidateFromSeed(seed, opts)
    local archetype = opts and opts.archetype or opts and opts.contractPattern
    if archetype == "composite_support_pressure_crusher_contact" or archetype == "composite_contact_pressure" then
        return composeCompositeSupportPressureCrusherCandidateFromSeed(seed, opts)
    end
    if archetype == "crusher_contact_breach" or archetype == "crusher_contact" then
        return composeCrusherContactCandidateFromSeed(seed, opts)
    end
    if archetype == "support_under_real_red_pressure" or archetype == "support_pressure" then
        return composeSupportPressureCandidateFromSeed(seed, opts)
    end
    if archetype == "support_intercepts_finisher_threat_artillery_finish" or archetype == "interceptor_artillery" then
        return composeInterceptorArtilleryCandidateFromSeed(seed, opts)
    end
    if archetype == "dual_rock_lock_ranged_finish" or archetype == "dual_rock_lock" then
        return composeDualRockLockCandidateFromSeed(seed, opts)
    end
    if archetype == "support_reposition_rock_los_finish" or archetype == "rock_los_finish" then
        return composeRichContractCandidateFromSeed(seed, opts)
    end

    if opts and opts.enableSupportPressure == true and normalizeSeed(seed) % 11 == 0 then
        local pressureCandidate, pressureReason = composeSupportPressureCandidateFromSeed(seed, opts)
        if pressureCandidate then
            return pressureCandidate
        end
        local richCandidate, richReason = composeRichContractCandidateFromSeed(seed, opts)
        if richCandidate then
            return richCandidate
        end
        return nil, richReason or pressureReason or "candidate_precondition_failed"
    end

    local richCandidate, richReason = composeRichContractCandidateFromSeed(seed, opts)
    if richCandidate then
        return richCandidate
    end
    if opts and opts.enableSupportPressure == true then
        local pressureCandidate, pressureReason = composeSupportPressureCandidateFromSeed(seed, opts)
        if pressureCandidate then
            return pressureCandidate
        end
        return nil, pressureReason or richReason or "candidate_precondition_failed"
    end
    return nil, richReason or "candidate_precondition_failed"
end

local function isCompositeArchetype(opts)
    local archetype = opts and opts.archetype or opts and opts.contractPattern
    return archetype == "composite_support_pressure_crusher_contact"
        or archetype == "composite_contact_pressure"
end

local function buildLayoutSearchCandidates(opts)
    if type(opts) ~= "table" or opts.layoutOffset or opts.layoutRowOffset or opts.layoutColOffset then
        return nil, {}
    end
    if opts.enableLayoutSearch ~= true and opts.layoutSearch ~= true then
        return nil, {}
    end
    if not isCompositeArchetype(opts) then
        return nil, {}
    end
    local candidates, rejected = compositionLayoutConstraints.enumerateLayoutCandidates(
        "composite_support_pressure_crusher_contact",
        {
            offsets = opts.layoutOffsets,
            maxCandidates = opts.layoutMaxCandidates
        }
    )
    local out = {}
    for _, layout in ipairs(candidates or {}) do
        out[#out + 1] = {
            layoutSpecId = layout.layoutSpecId,
            variant = layout.variant,
            rowOffset = tonumber(layout.rowOffset) or 0,
            colOffset = tonumber(layout.colOffset) or 0
        }
    end
    return out, rejected or {}
end

local function orderedLayoutSearchCandidates(candidates, seed)
    if type(candidates) ~= "table" or #candidates == 0 then
        return { false }
    end
    local out = {}
    local start = (normalizeSeed(seed) % #candidates) + 1
    local i
    for i = 0, #candidates - 1 do
        out[#out + 1] = candidates[((start + i - 1) % #candidates) + 1]
    end
    return out
end

function M.isScenarioOnly()
    return true
end

function M.precheck(opts)
    local turnLimit = normalizeTurnLimit(opts)
    local nValue = normalizeN(opts)
    local ok = true
    local report = {
        ok = true,
        checks = {},
        turnLimit = turnLimit,
        N = nValue,
        constraints = {
            turnLimitRange = "3..10",
            supportsN3 = true,
            scenarioOnly = true
        }
    }

    if turnLimit < 3 or turnLimit > 10 then
        ok = false
        report.checks[#report.checks + 1] = {
            check = "turn_limit_range",
            ok = false,
            message = "turnLimit must be between 3 and 10."
        }
    else
        report.checks[#report.checks + 1] = {
            check = "turn_limit_range",
            ok = true
        }
    end

    if nValue ~= 3 then
        ok = false
        report.checks[#report.checks + 1] = {
            check = "n_equals_3_supported",
            ok = false,
            message = "Retro-generator core V1 supports N=3 certification."
        }
    else
        report.checks[#report.checks + 1] = {
            check = "n_equals_3_supported",
            ok = true
        }
    end

    local finisherOk, finisherReports = finisherLibrary.validateLibrary()
    report.finisherLibrary = {
        ok = finisherOk == true,
        report = finisherReports
    }
    report.finisherLibraryOk = finisherOk == true
    if not finisherOk then
        ok = false
    end
    report.checks[#report.checks + 1] = {
        check = "finisher_library_validate",
        ok = finisherOk == true
    }

    local microOk, microReports = microLibrary.validateLibrary()
    report.microLibrary = {
        ok = microOk == true,
        report = microReports
    }
    report.microLibraryOk = microOk == true
    if not microOk then
        ok = false
    end
    report.checks[#report.checks + 1] = {
        check = "micro_library_validate",
        ok = microOk == true
    }

    local micros = microLibrary.listMicroInteractions()
    local macroViolations = {}
    local i
    for i = 1, #micros do
        local spec = micros[i]
        if hasMacroField(spec) or microLibrary.isMacroTemplate(spec) then
            macroViolations[#macroViolations + 1] = spec.id
        end
    end
    report.checks[#report.checks + 1] = {
        check = "no_macro_templates",
        ok = #macroViolations == 0,
        violations = macroViolations
    }
    report.macroTemplateCount = #macroViolations
    if #macroViolations > 0 then
        ok = false
    end

    report.ok = ok
    return ok, report
end

function M.certifyCandidate(candidate, opts)
    local proofDomain = normalizeProofDomain(opts)
    local noveltyThreshold = tonumber(opts and opts.noveltyThreshold) or DEFAULT_NOVELTY_THRESHOLD
    local rejectionReasons = {}
    local diagnostics = {
        candidateSeed = candidate and candidate.seed or nil,
        proofDomain = proofDomain
    }

    if type(candidate) ~= "table" or type(candidate.scenarioState) ~= "table" then
        local rejected = {
            schema = "GenerationDossier",
            id = "retro_rejected_missing_candidate",
            seed = (candidate and candidate.seed) or normalizeSeed(opts and opts.seed),
            pipelineState = "not_generated",
            scenarioState = (candidate and candidate.scenarioState) or {},
            mechanismSpec = {},
            tacticalFingerprint = {},
            microInteractions = {},
            finisher = {},
            solution = {},
            falseLines = {},
            proofCertificate = {},
            solverProof = {},
            rejectionReasons = {
                buildRejection("candidate_missing_state", "contract", "Candidate scenarioState is missing.")
            },
            qualityFeatures = {},
            qualityFeatureSet = {
                schema = "QualityFeatureSet",
                feature_version = "retro_generator_v1",
                features = {},
                component_scores = {},
                total_score = 0,
                pass = false,
                reasons = { "candidate_missing_state" }
            },
            predicateResults = {}
        }
        return rejected, diagnostics
    end

    local candidateState = stateEngine.normalize(candidate.scenarioState)
    local maxActions = tonumber(candidateState.maxActionsPerTurn) or 0
    diagnostics.maxActionsPerTurn = maxActions
    local compositeIssue = compositeContractIssue(candidate)
    if compositeIssue then
        rejectionReasons[#rejectionReasons + 1] = buildRejection(
            compositeIssue.code,
            "contract",
            compositeIssue.message,
            compositeIssue.evidence
        )
    end
    if maxActions ~= CONTRACT_MAX_ACTIONS_PER_TURN then
        rejectionReasons[#rejectionReasons + 1] = buildRejection(
            "action_budget_non_compliant",
            "contract",
            "ScenarioState maxActionsPerTurn must be exactly 2 for runtime budget compliance.",
            { actual = maxActions, expected = CONTRACT_MAX_ACTIONS_PER_TURN }
        )
    end

    local mechanismSpec = buildMechanismSpec(candidate, proofDomain)
    local envelope = {
        scenarioState = candidateState,
        mechanismSpec = mechanismSpec,
        tacticalFingerprint = candidate.tacticalFingerprint
    }
    local validState, stateErrors = scenarioValidator.validateScenarioState(envelope)
    if not validState then
        rejectionReasons[#rejectionReasons + 1] = buildRejection(
            "scenario_state_contract_failed",
            "contract",
            "ScenarioState failed contract validation.",
            stateErrors
        )
    end

    local i
    for i = 1, #(candidate.microInteractions or {}) do
        local microId = candidate.microInteractions[i]
        local validMicro = microLibrary.validateMicroInteraction(microId)
        local spec = microLibrary.getMicroInteraction(microId)
        if not validMicro then
            rejectionReasons[#rejectionReasons + 1] = buildRejection(
                "micro_interaction_invalid",
                "contract",
                "Micro interaction failed validation: " .. stableString(microId)
            )
        elseif hasMacroField(spec) or microLibrary.isMacroTemplate(spec) then
            rejectionReasons[#rejectionReasons + 1] = buildRejection(
                "macro_template_forbidden",
                "contract",
                "Macro-template fields are forbidden in micro interactions.",
                microId
            )
        end
    end

    local solverOpts = buildSolverOptions(candidate, opts, proofDomain)
    local solveProof = solver.solve(candidateState, solverOpts)
    diagnostics.solveStatus = solveProof.status
    if solveProof.status ~= "forced_win" then
        rejectionReasons[#rejectionReasons + 1] = buildRejection(
            "solver_not_forced_win",
            "solver",
            "Solver did not prove forced win.",
            solveProof
        )
    end
    if (tonumber(candidateState.turnLimit) or 0) == 3 and (tonumber(candidateState.scenarioTurn) or 1) <= 1 then
        local twoTurnState = deepCopy(candidateState)
        twoTurnState.turnLimit = 2
        twoTurnState.scenarioTurn = 1
        local redPassBound = solver.proveNoBlueWinEvenIfRedPasses(twoTurnState, solverOpts)
        diagnostics.twoTurnRedPassBoundStatus = redPassBound.status
        local twoTurnProof = redPassBound
        if redPassBound.status == "no_blue_win_even_with_red_pass" then
            diagnostics.twoTurnSolveStatus = "unsolved_by_red_pass_bound"
        else
            twoTurnProof = solver.solve(twoTurnState, solverOpts)
            diagnostics.twoTurnSolveStatus = twoTurnProof.status
        end
        if twoTurnProof.status == "forced_win" then
            rejectionReasons[#rejectionReasons + 1] = buildRejection(
                "turn_limit_not_binding",
                "contract",
                "N=3 scenario is solvable within two turns under the real action budget.",
                twoTurnProof
            )
        elseif twoTurnProof.status == "unknown" then
            rejectionReasons[#rejectionReasons + 1] = buildRejection(
                "turn_limit_binding_unknown",
                "compute_limit",
                "Solver could not prove that the N=3 turn limit is binding within the compute budget.",
                twoTurnProof
            )
        end
    end

    local falseLines = {}
    local provenFalseCount = 0
    local candidateLines = {}
    if type(candidate.preferredFalseLine) == "table" and #candidate.preferredFalseLine > 0 then
        candidateLines[#candidateLines + 1] = candidate.preferredFalseLine
    end

    local openingLegal = stateEngine.getLegalActions(candidateState)
    local winningFirst = solveProof and solveProof.winningLine and solveProof.winningLine[1] or nil
    local fallbackFalse = nil
    for i = 1, #openingLegal do
        local a = openingLegal[i]
        if a.type == "attack" and stableString(a.targetId) == "red_decoy" then
            candidateLines[#candidateLines + 1] = { canonicalAction(a) }
            break
        end
    end
    for i = 1, #openingLegal do
        local a = openingLegal[i]
        if not actionMatches(a, winningFirst) then
            fallbackFalse = { canonicalAction(a) }
            break
        end
    end
    if fallbackFalse then
        candidateLines[#candidateLines + 1] = fallbackFalse
    end

    local seenLineHash = {}
    for i = 1, #candidateLines do
        local line = candidateLines[i]
        local lineHashParts = {}
        local li
        for li = 1, #line do
            lineHashParts[#lineHashParts + 1] = stableString(line[li] and line[li].id)
        end
        local lineHash = hashText(table.concat(lineHashParts, "|"))
        if not seenLineHash[lineHash] then
            seenLineHash[lineHash] = true
            local proof = proveRichFalseLineByTempo(candidate, line)
                or solver.proveFalseLine(candidateState, line, solverOpts)
            local verified = proof.status == "false_line_proven"
            if verified then
                provenFalseCount = provenFalseCount + 1
                falseLines[#falseLines + 1] = {
                    schema = "FalseLineProof",
                    actions = deepCopy(line),
                    line = deepCopy(line),
                    verified = true,
                    result = proof.status,
                    reason = proof.reason,
                    proof = proof,
                    evidence = proof
                }
                if provenFalseCount >= 1 then
                    break
                end
            end
        end
    end

    diagnostics.falseLineProofs = #falseLines
    diagnostics.falseLinesProven = provenFalseCount
    if provenFalseCount == 0 then
        rejectionReasons[#rejectionReasons + 1] = buildRejection(
            "false_line_not_proven",
            "solver",
            "At least one plausible false line must be proven via solver.proveFalseLine.",
            falseLines
        )
    end

    local variety = buildVarietyFeatures(candidate)
    local novelty = candidate.tacticalFingerprint and candidate.tacticalFingerprint.noveltyScore or 0
    if novelty < noveltyThreshold then
        rejectionReasons[#rejectionReasons + 1] = buildRejection(
            "novelty_below_threshold",
            "novelty",
            "Novelty is below configured threshold.",
            {
                novelty = novelty,
                threshold = noveltyThreshold
            }
        )
    end
    if not variety.pass then
        rejectionReasons[#rejectionReasons + 1] = buildRejection(
            "native_variety_low",
            "quality",
            "Native variety metrics did not pass without history.",
            variety
        )
    end

    local certified = #rejectionReasons == 0
    local qualityPack = packQuality(candidate, variety, noveltyThreshold, certified)
    local contractEvidence = candidate.contractEvidence or {}
    local pressureFeature = "red_decoy"
    local pressureReason = "red_decoy is a legal false target whose line is solver-proven losing."
    local nonDecorativeReason = "Removing support reposition or Rock clear removes the legal commandant shot."
    local staticClockReason = "winning line requires support reposition, Rock removal, LOS conversion, and finisher cell gain."
    local freeFinisherReason = "finisher cannot legally shoot Commandant from the required cell until Rock is removed."
    local supportFreeReason = "support starts outside the key attack cell and has no legal Rock attack before repositioning."
    local preventedText = candidate.contractPattern == "support_under_real_red_pressure"
        and "support Rock-clear interaction before the final Commandant shot"
        or "final Commandant shot inside turn limit"
    if candidate.contractPattern == "support_under_real_red_pressure" then
        pressureFeature = "red_support_threat"
        pressureReason = "red_support_threat has a policy-selected move+attack that kills support if Blue loses tempo."
    elseif candidate.contractPattern == "support_intercepts_finisher_threat_artillery_finish" then
        pressureFeature = "red_interceptor"
        pressureReason = "red_interceptor has a policy-selected move+attack that kills the critical Artillery finisher if Blue skips support interception."
        nonDecorativeReason = "Removing the support intercept lets Red remove the only Artillery finisher before the payoff cell is reached."
        staticClockReason = "winning line requires support interception, Artillery staging, final cell gain, and exact payoff."
        freeFinisherReason = "Artillery cannot reach the final orthogonal firing cell and attack inside two turns."
        supportFreeReason = "support starts outside the interceptor-clear cell and has no opening attack on the interceptor."
        preventedText = "Red interceptor kill on the critical Artillery finisher"
    elseif candidate.contractPattern == "dual_rock_lock_ranged_finish" then
        pressureFeature = "dual_rock_lock_chain"
        pressureReason = "two independent Rock locks make the support tempo real; skipping either lock leaves no N=3 forced win."
        nonDecorativeReason = "Removing either Rock conversion leaves the Cloudstriker line blocked or the action budget short."
        staticClockReason = "winning line requires lower Rock conversion, upper Rock conversion, final cell gain, and exact payoff."
        freeFinisherReason = "Cloudstriker can move toward the final cell, but cannot use it for a Commandant kill until both Rock locks are converted."
        supportFreeReason = "support starts outside both Rock-clear cells and has no opening attack on either Rock lock."
        preventedText = "single-lock shortcut into the final Cloudstriker line"
    elseif candidate.contractPattern == "crusher_contact_breach"
        or candidate.contractPattern == "composite_support_pressure_crusher_contact" then
        pressureFeature = "red_contact_blocker"
        pressureReason = "contact blocker and wrong-tempo lines are solver-proven losing before Crusher contact."
        nonDecorativeReason = "Removing contact-cell gain or blocker resolution removes the legal melee Commandant attack."
        staticClockReason = "winning line requires melee contact positioning, blocker tempo, and exact Crusher payoff."
        freeFinisherReason = "Crusher cannot reach the required adjacent contact cell and attack inside two turns."
        supportFreeReason = "support starts outside the blocker interaction cell and has no opening attack on the contact blocker."
        preventedText = "Crusher adjacent contact attack inside the turn limit"
        if candidate.contractPattern == "composite_support_pressure_crusher_contact" then
            pressureFeature = "red_support_threat"
            pressureReason = "red_support_threat has a policy-selected move+attack that kills support if Blue skips setup."
            nonDecorativeReason = "Removing either support-pressure answer or Crusher contact gain breaks the composite line."
            staticClockReason = "winning line combines support pressure, blocker resolution, Crusher staging, and exact melee payoff."
            preventedText = "Red support kill plus blocked Crusher contact line"
        end
    end
    local predicateResults = {
        predicateEntry("critical_blue_unit", true, {
            support = "blue_a_support",
            finisher = "blue_finisher",
            evidence = contractEvidence
        }),
        predicateEntry("macro_template_signature", false, { generator = M.GENERATOR_ID }),
        predicateEntry("fingerprint_distinct", novelty >= noveltyThreshold, {
            noveltyScore = novelty,
            threshold = noveltyThreshold
        }),
        predicateEntry("non_decorative_micro", true, {
            microInteractions = candidate.microInteractions,
            ablationSignal = nonDecorativeReason
        }),
        predicateEntry("static_damage_clock", false, {
            reason = staticClockReason
        }),
        predicateEntry("multi_unit_damage_clock", false, {
            reason = "support action changes board topology instead of adding Commandant damage."
        }),
        predicateEntry("free_finisher_move", false, {
            reason = freeFinisherReason,
            rockBlocksFinisherShotBeforeClear = contractEvidence.rockBlocksFinisherShotBeforeClear
        }),
        predicateEntry("support_already_free", false, {
            reason = supportFreeReason,
            supportMustReposition = contractEvidence.supportMustReposition,
            requiredSupportCell = contractEvidence.requiredSupportCell
        }),
        predicateEntry("cosmetic_red_pressure", false, {
            reason = pressureReason,
            falseLinesProven = provenFalseCount
        }),
        predicateEntry("real_pressure", true, {
            pressureFeature = pressureFeature,
            redSupportThreatCanKillBeforeSetup = contractEvidence.redSupportThreatCanKillBeforeSetup,
            falseLinesProven = provenFalseCount
        }),
        predicateEntry("required_line", solveProof.status == "forced_win", {
            winningLineLength = #(solveProof.winningLine or {})
        }),
        predicateEntry("required_cell", true, {
            attackCell = candidate.attackCellText,
            supportCell = contractEvidence.requiredSupportCell,
            rockCell = contractEvidence.rockCell
        }),
        predicateEntry("gains_time", provenFalseCount > 0, {
            falseLinesProven = provenFalseCount
        }),
        predicateEntry("position_gained", true, {
            supportCell = contractEvidence.requiredSupportCell,
            finisherCell = contractEvidence.requiredFinisherCell
        }),
        predicateEntry("prevents_micro_interaction", true, {
            falseTarget = pressureFeature,
            prevented = preventedText
        })
    }

    local proofCertificate = buildProofCertificate(candidate, solveProof, falseLines, proofDomain)
    local dossier = {
        schema = "GenerationDossier",
        id = "retro_" .. hashText(stableString(candidate.seed) .. "|" .. candidate.tacticalFingerprint.hash),
        seed = candidate.seed,
        contractPattern = candidate.contractPattern,
        schemaFreezeVersion = schemaContract.freeze and schemaContract.freeze.version or "unknown",
        predicateFreezeVersion = predicateContract.module and predicateContract.module.version or "unknown",
        pipelineState = certified and "certified" or "candidate",
        scenarioState = deepCopy(candidateState),
        mechanismSpec = mechanismSpec,
        tacticalFingerprint = deepCopy(candidate.tacticalFingerprint),
        microInteractions = {},
        finisher = {
            id = candidate.finisher.id,
            family = candidate.finisher.family,
            unitType = candidate.finisher.unitType,
            damageVsCommandant = candidate.finisher.damageVsCommandant
        },
        solution = {
            actions = shallowCopyArray(solveProof.winningLine or {})
        },
        scenarioRedPolicy = deepCopy(candidate.scenarioRedPolicy or {}),
        falseLines = falseLines,
        proofCertificate = proofCertificate,
        solverProof = solveProof,
        rejectionReasons = rejectionReasons,
        qualityFeatures = qualityPack.qualityFeatures,
        qualityFeatureSet = qualityPack.qualityFeatureSet,
        predicateResults = predicateResults,
        compositionalContract = deepCopy(candidate.compositionalContract or {}),
        ablationResults = deepCopy(candidate.actionConsequences or {})
    }
    dossier.tacticalFingerprint.signature = dossier.tacticalFingerprint.hash
    for i = 1, #(candidate.microInteractions or {}) do
        dossier.microInteractions[i] = { id = candidate.microInteractions[i] }
    end
    if proofDomain == "defensive" then
        dossier.defensiveProofUsed = true
        dossier.defensiveDomainDecisions = solveProof.defensiveDomainDecisions or {}
    else
        dossier.defensiveProofUsed = false
        dossier.defensiveDomainDecisions = {}
    end

    local dossierOk, dossierErrors = scenarioValidator.validateScenarioDossier(dossier)
    diagnostics.dossierValid = dossierOk
    if not dossierOk then
        dossier.pipelineState = "candidate"
        dossier.rejectionReasons[#dossier.rejectionReasons + 1] = buildRejection(
            "scenario_dossier_contract_failed",
            "contract",
            "GenerationDossier failed contract validation.",
            dossierErrors
        )
    end

    return dossier, diagnostics
end

function M.generate(opts)
    opts = opts or {}
    local preOk, preReport = M.precheck(opts)
    local baseSeed = normalizeSeed(opts.seed or 1)
    local diagnostics = {
        precheck = preReport,
        baseSeed = baseSeed,
        attempts = 0,
        certified = false,
        attemptSeeds = {},
        layoutAttempts = {},
        layoutSearch = {
            enabled = false,
            candidates = {},
            rejected = {}
        },
        rejectionCodes = {}
    }

    if not preOk then
        return {
            schema = "GenerationDossier",
            id = "retro_precheck_failed_" .. hashText(stableString(baseSeed)),
            seed = baseSeed,
            schemaFreezeVersion = schemaContract.freeze and schemaContract.freeze.version or "unknown",
            predicateFreezeVersion = predicateContract.module and predicateContract.module.version or "unknown",
            pipelineState = "not_generated",
            scenarioState = {},
            mechanismSpec = {},
            tacticalFingerprint = {},
            microInteractions = {},
            finisher = {},
            solution = {},
            falseLines = {},
            proofCertificate = {},
            solverProof = {},
            rejectionReasons = {
                buildRejection("precheck_failed", "contract", "Retro-generator precheck failed.", preReport)
            },
            qualityFeatures = {},
            qualityFeatureSet = {
                schema = "QualityFeatureSet",
                feature_version = "retro_generator_v1",
                features = {},
                component_scores = {},
                total_score = 0,
                pass = false,
                reasons = { "precheck_failed" }
            },
            predicateResults = {}
        }, diagnostics
    end

    local maxAttempts = tonumber(opts.maxAttempts) or DEFAULT_MAX_CERT_ATTEMPTS
    local layoutSearchCandidates, layoutSearchRejected = buildLayoutSearchCandidates(opts)
    if layoutSearchCandidates then
        diagnostics.layoutSearch = {
            enabled = true,
            candidates = deepCopy(layoutSearchCandidates),
            rejected = deepCopy(layoutSearchRejected)
        }
    end
    local attempt
    local lastDossier = nil
    for attempt = 1, maxAttempts do
        local attemptSeed = (baseSeed + ((attempt - 1) * 2654435761)) % 4294967296

        for _, layoutCandidate in ipairs(orderedLayoutSearchCandidates(layoutSearchCandidates, attemptSeed)) do
            diagnostics.attempts = diagnostics.attempts + 1
            diagnostics.attemptSeeds[#diagnostics.attemptSeeds + 1] = attemptSeed
            local attemptOpts = opts
            if layoutCandidate then
                attemptOpts = deepCopy(opts)
                attemptOpts.enableLayoutSearch = false
                attemptOpts.layoutSearch = false
                attemptOpts.layoutOffset = {
                    rowOffset = layoutCandidate.rowOffset,
                    colOffset = layoutCandidate.colOffset
                }
                diagnostics.layoutAttempts[#diagnostics.layoutAttempts + 1] = {
                    seed = attemptSeed,
                    layoutSpecId = layoutCandidate.layoutSpecId,
                    variant = layoutCandidate.variant,
                    rowOffset = layoutCandidate.rowOffset,
                    colOffset = layoutCandidate.colOffset
                }
            end

            local candidate, composeErr = composeCandidateFromSeed(attemptSeed, attemptOpts)
            if candidate then
                local dossier, certDiag = M.certifyCandidate(candidate, attemptOpts)
                diagnostics.lastCertification = certDiag
                lastDossier = dossier
                if dossier.pipelineState == "certified" then
                    diagnostics.certified = true
                    return dossier, diagnostics
                end
                local i
                for i = 1, #(dossier.rejectionReasons or {}) do
                    local code = dossier.rejectionReasons[i].code
                    diagnostics.rejectionCodes[code] = (diagnostics.rejectionCodes[code] or 0) + 1
                end
            else
                diagnostics.rejectionCodes[composeErr or "compose_failed"] =
                    (diagnostics.rejectionCodes[composeErr or "compose_failed"] or 0) + 1
            end
        end
    end

    if lastDossier then
        return lastDossier, diagnostics
    end

    return {
        schema = "GenerationDossier",
        id = "retro_generation_failed_" .. hashText(stableString(baseSeed)),
        seed = baseSeed,
        schemaFreezeVersion = schemaContract.freeze and schemaContract.freeze.version or "unknown",
        predicateFreezeVersion = predicateContract.module and predicateContract.module.version or "unknown",
        pipelineState = "not_generated",
        scenarioState = {},
        mechanismSpec = {},
        tacticalFingerprint = {},
        microInteractions = {},
        finisher = {},
        solution = {},
        falseLines = {},
        proofCertificate = {},
        solverProof = {},
        rejectionReasons = {
            buildRejection("generation_exhausted", "compute_limit", "Unable to compose a certifiable candidate.")
        },
        qualityFeatures = {},
        qualityFeatureSet = {
            schema = "QualityFeatureSet",
            feature_version = "retro_generator_v1",
            features = {},
            component_scores = {},
            total_score = 0,
            pass = false,
            reasons = { "generation_exhausted" }
        },
        predicateResults = {}
    }, diagnostics
end

function M.generateBatch(opts)
    opts = opts or {}
    local count = tonumber(opts.count) or DEFAULT_BATCH_COUNT
    if count < 1 then
        count = 1
    end
    count = math.floor(count)

    local baseSeed = normalizeSeed(opts.seed or 1)
    local dossiers = {}
    local summary = {
        schema = "GenerationBatchSummary",
        requestedCount = count,
        certifiedCount = 0,
        attempts = 0,
        failedCount = 0,
        distinctFingerprintCount = 0,
        distinctSeedCount = 0,
        seedsTried = {},
        rejectionCounts = {},
        noveltyRejectRate = 0,
        maxNoveltyRejectRate = tonumber(opts.maxNoveltyRejectRate) or 0.45
    }

    local seenFingerprints = {}
    local seenSeeds = {}
    local maxAttempts = tonumber(opts.batchMaxAttempts) or (count * 40)
    local i
    for i = 1, maxAttempts do
        if #dossiers >= count then
            break
        end
        local seed = (baseSeed + (i * 362437)) % 4294967296
        summary.attempts = summary.attempts + 1
        summary.seedsTried[#summary.seedsTried + 1] = seed

        local oneOpts = deepCopy(opts)
        oneOpts.seed = seed
        oneOpts.maxAttempts = tonumber(opts.maxAttempts) or 24
        local dossier = M.generate(oneOpts)
        if type(dossier) == "table" and dossier.pipelineState == "certified" and dossier.tacticalFingerprint then
            local fp = stableString(dossier.tacticalFingerprint.hash)
            if fp ~= "" and not seenFingerprints[fp] then
                seenFingerprints[fp] = true
                dossiers[#dossiers + 1] = dossier
                seenSeeds[stableString(dossier.seed)] = true
            end
        else
            summary.failedCount = summary.failedCount + 1
            if type(dossier) == "table" then
                local j
                for j = 1, #(dossier.rejectionReasons or {}) do
                    local code = stableString(dossier.rejectionReasons[j].code)
                    summary.rejectionCounts[code] = (summary.rejectionCounts[code] or 0) + 1
                end
            end
        end
    end

    summary.certifiedCount = #dossiers
    summary.distinctFingerprintCount = tableLength(seenFingerprints)
    summary.distinctSeedCount = tableLength(seenSeeds)
    local noveltyRejects = summary.rejectionCounts.novelty_below_threshold or 0
    summary.noveltyRejectRate = summary.attempts > 0 and (noveltyRejects / summary.attempts) or 0
    summary.ok = summary.certifiedCount >= count
    summary.turnLimit = normalizeTurnLimit(opts)
    summary.N = normalizeN(opts)
    return dossiers, summary
end

M.GENERATOR_HASH = hashText(table.concat({
    M.VERSION,
    M.GENERATOR_ID,
    finisherLibrary.VERSION or "",
    finisherLibrary.LIBRARY_HASH or "",
    microLibrary.VERSION or "",
    microLibrary.LIBRARY_HASH or "",
    stateEngine.VERSION or "",
    solver.VERSION or "",
    scenarioValidator.VERSION or ""
}, "|"))

return M
