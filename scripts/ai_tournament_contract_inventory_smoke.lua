package.path = package.path .. ";./?.lua"

local results = {}

local function runTest(name, fn)
    local startedAt = os.clock()
    local ok, err = xpcall(fn, debug.traceback)
    local elapsedMs = (os.clock() - startedAt) * 1000
    results[#results + 1] = {
        name = name,
        ok = ok,
        err = err,
        ms = elapsedMs
    }
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

local function ensureHeadlessGlobals()
    _G.love = _G.love or {}
    love.timer = love.timer or {}
    love.timer.getTime = love.timer.getTime or os.clock
    love.audio = love.audio or {}
    love.audio.newSource = love.audio.newSource or function()
        local source = {}
        function source:clone() return self end
        function source:play() end
        function source:stop() end
        function source:seek() end
        function source:setVolume() end
        function source:setPitch() end
        return source
    end

    _G.SETTINGS = _G.SETTINGS or {
        PERF = {
            LOG_LEVEL = "warn",
            LOG_CATEGORIES = {
                AI = false,
                GAMEPLAY = false,
                GRID = false,
                UI = false,
                PERF = false
            }
        },
        AUDIO = {
            SFX = false,
            SFX_VOLUME = 0
        },
        DISPLAY = {
            WIDTH = 1280,
            HEIGHT = 720,
            SCALE = 1,
            OFFSETX = 0,
            OFFSETY = 0
        }
    }

    _G.DEBUG = _G.DEBUG or {}
    DEBUG.AI = false

    _G.GAME = _G.GAME or {}
    GAME.CONSTANTS = GAME.CONSTANTS or {}
    GAME.CONSTANTS.GRID_SIZE = GAME.CONSTANTS.GRID_SIZE or 8
    GAME.CONSTANTS.MAX_ACTIONS_PER_TURN = GAME.CONSTANTS.MAX_ACTIONS_PER_TURN or 2
    GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE = GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE or 10

    GAME.MODE = GAME.MODE or {
        AI_VS_AI = "ai_vs_ai",
        MULTYPLAYER_LOCAL = "multi_local",
        MULTYPLAYER_NET = "multi_net"
    }

    GAME.CURRENT = GAME.CURRENT or {}
    GAME.CURRENT.TURN = GAME.CURRENT.TURN or 1
    GAME.CURRENT.MODE = GAME.CURRENT.MODE or GAME.MODE.AI_VS_AI
    GAME.CURRENT.AI_PLAYER_NUMBER = GAME.CURRENT.AI_PLAYER_NUMBER or 1

    GAME.getAIFactionId = GAME.getAIFactionId or function()
        return GAME.CURRENT.AI_PLAYER_NUMBER or 1
    end

    GAME.isFactionControlledByAI = GAME.isFactionControlledByAI or function()
        return true
    end
end

local function mkAI(factionId)
    local AI = require("ai")
    local ai = AI.new({factionId = factionId})
    ai.grid = {
        getUnitAt = function()
            return nil
        end
    }
    return ai
end

local function contains(values, wanted)
    for _, value in ipairs(values or {}) do
        if value == wanted then
            return true
        end
    end
    return false
end

local function chooseFixture(fixtureId)
    ensureHeadlessGlobals()
    local brain = require("ai_tournament.brain")
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local fixture = fixtureLib.getFixture(fixtureId)
    assertTrue(fixture ~= nil, "missing fixture " .. tostring(fixtureId))

    local player = fixture.actingPlayer or 1
    GAME.CURRENT.AI_PLAYER_NUMBER = player
    local ai = mkAI(player)
    local sequence, meta = brain.chooseTurn(ai, fixture.state, {
        maxActions = 2,
        decisionStartTime = love.timer.getTime(),
        softBudgetMs = 900,
        hardBudgetMs = 1200
    })
    assertTrue(type(sequence) == "table" and #sequence > 0, fixtureId .. " should return a sequence")
    assertTrue(type(meta) == "table", fixtureId .. " should return metadata")
    return sequence, meta
end

local function choosePureCombatState()
    ensureHeadlessGlobals()
    local brain = require("ai_tournament.brain")
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local state = fixtureLib.buildBaseState({
        actingPlayer = 1,
        turnNumber = 3,
        turnsWithoutDamage = 0,
        playerOneHub = {name = "Commandant", player = 1, row = 1, col = 1, currentHp = 12, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            {name = "Crusher", player = 1, row = 4, col = 4, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Bastion", player = 2, row = 4, col = 5, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Bastion", player = 2, row = 6, col = 6, currentHp = 6, startingHp = 6, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Cloudstriker", player = 2, row = 6, col = 5, currentHp = 4, startingHp = 4, hasActed = false, hasMoved = false, actionsUsed = 0},
            {name = "Earthstalker", player = 2, row = 7, col = 6, currentHp = 3, startingHp = 3, hasActed = false, hasMoved = false, actionsUsed = 0}
        },
        supplyOne = {}
    })

    GAME.CURRENT.AI_PLAYER_NUMBER = 1
    local ai = mkAI(1)
    local sequence, meta = brain.chooseTurn(ai, state, {
        maxActions = 2,
        decisionStartTime = love.timer.getTime(),
        softBudgetMs = 900,
        hardBudgetMs = 1200
    })
    assertTrue(type(sequence) == "table" and #sequence > 0, "pure combat state should return a sequence")
    assertTrue(type(meta) == "table", "pure combat state should return metadata")
    return sequence, meta
end

local function activeContracts(meta)
    return (meta and meta.contractEvidence and meta.contractEvidence.activeContracts) or {}
end

local function assertActive(meta, contract)
    assertTrue(contains(activeContracts(meta), contract), "expected active contract " .. tostring(contract))
end

local function assertNoTechnicalFallback(meta)
    local stats = meta and meta.stats or {}
    assertTrue(meta.contract ~= "TECHNICAL_FALLBACK", "contract should not be technical fallback")
    assertTrue(stats.fallbackSource ~= "technical_fallback", "selection should not be technical fallback")
end

runTest("contract_inventory_is_exported", function()
    ensureHeadlessGlobals()
    local contracts = require("ai_tournament.brain").CONTRACTS
    local expected = {
        "WIN_NOW",
        "DEFEND_NOW",
        "COMBAT_OR_DRAW_RESET",
        "CONVERT_WINNING_POSITION",
        "BREAK_DRAW_CLOCK",
        "FORCE_COMMANDANT_PRESSURE",
        "ELIMINATE_LOW_HP_UNIT",
        "CONVERT_ADVANTAGE",
        "BUILD_POSITION",
        "TECHNICAL_FALLBACK"
    }

    for _, name in ipairs(expected) do
        assertEquals(contracts[name], name, "contract inventory should expose " .. name)
    end
end)

runTest("hard_and_v2_contracts_survive_exact_sanitize", function()
    local _, winMeta = chooseFixture("immediate_commandant_lethal")
    assertEquals(winMeta.contract, "WIN_NOW", "immediate commandant lethal should select WIN_NOW")
    assertEquals(winMeta.stats.hardSelectionLocked, true, "WIN_NOW should be hard locked")
    assertEquals(winMeta.stats.hardSelectionReason, "win_now", "WIN_NOW hard reason")
    assertEquals(winMeta.stats.coreExit, "hard_contract", "WIN_NOW should exit before core")
    assertActive(winMeta, "WIN_NOW")
    assertNoTechnicalFallback(winMeta)

    local _, defendMeta = chooseFixture("immediate_commandant_defense")
    assertEquals(defendMeta.contract, "DEFEND_NOW", "immediate commandant threat should select DEFEND_NOW")
    assertEquals(defendMeta.stats.hardSelectionLocked, true, "DEFEND_NOW should be hard locked")
    assertEquals(defendMeta.stats.hardSelectionReason, "defend_now", "DEFEND_NOW hard reason")
    assertActive(defendMeta, "DEFEND_NOW")
    assertNoTechnicalFallback(defendMeta)

    local _, killMeta = chooseFixture("safe_kill_beats_rebuild_when_ahead")
    assertEquals(killMeta.contract, "ELIMINATE_LOW_HP_UNIT", "safe kill should select eliminate contract")
    assertEquals(killMeta.stats.coreExit, "pipeline_v2_mid_selected", "mid safe kill should be owned by V2")
    assertTrue(killMeta.stats.hardSelectionLocked ~= true, "mid safe kill should not require hard lock")
    assertTrue((tonumber(killMeta.stats.selectedKillCount) or 0) > 0, "safe kill selection should kill a unit")
    assertActive(killMeta, "ELIMINATE_LOW_HP_UNIT")
    assertNoTechnicalFallback(killMeta)
end)

runTest("core_contract_lanes_cover_non_locked_priorities", function()
    local _, combatMeta = choosePureCombatState()
    assertEquals(combatMeta.contract, "COMBAT_OR_DRAW_RESET", "pure combat should select combat contract")
    assertActive(combatMeta, "COMBAT_OR_DRAW_RESET")
    assertActive(combatMeta, "CONVERT_ADVANTAGE")
    assertActive(combatMeta, "BUILD_POSITION")
    assertEquals(combatMeta.stats.conversionContractActive, false, "pure combat should not activate conversion-specific contracts")
    assertTrue(combatMeta.stats.selectedHasFactionAttack == true, "pure combat should select a faction attack")
    assertNoTechnicalFallback(combatMeta)

    local _, drawMeta = chooseFixture("combat_required_under_draw_pressure")
    assertEquals(drawMeta.contract, "BREAK_DRAW_CLOCK", "draw pressure should select break draw clock")
    assertActive(drawMeta, "BREAK_DRAW_CLOCK")
    assertActive(drawMeta, "COMBAT_OR_DRAW_RESET")
    assertTrue(drawMeta.stats.selectedHasFactionAttack == true, "draw pressure should select combat")
    assertNoTechnicalFallback(drawMeta)

    local _, pressureMeta = chooseFixture("enemy_supply_present")
    assertEquals(pressureMeta.contract, "FORCE_COMMANDANT_PRESSURE", "pressure fixture should select commandant pressure")
    assertActive(pressureMeta, "FORCE_COMMANDANT_PRESSURE")
    assertTrue((tonumber(pressureMeta.stats.selectedCommandantDamage) or 0) > 0, "pressure contract should damage commandant")
    assertNoTechnicalFallback(pressureMeta)

    local _, conversionMeta = chooseFixture("deploy_plus_attack")
    assertEquals(conversionMeta.contract, "CONVERT_WINNING_POSITION", "advantage fixture should select winning conversion")
    assertActive(conversionMeta, "CONVERT_WINNING_POSITION")
    assertTrue(conversionMeta.stats.conversionContractActive == true, "conversion contract should be active")
    assertNoTechnicalFallback(conversionMeta)

    local _, buildMeta = chooseFixture("kernel_returns_legal_non_skip_when_no_combat_exists")
    assertEquals(buildMeta.contract, "BUILD_POSITION", "no-combat fixture should select build position")
    assertActive(buildMeta, "BUILD_POSITION")
    assertTrue(buildMeta.stats.selectedHasFactionAttack ~= true, "build position should not require faction attack")
    assertNoTechnicalFallback(buildMeta)
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Contract Inventory Smoke"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "- Generated: " .. os.date("%Y-%m-%d %H:%M:%S")
    lines[#lines + 1] = "- Passed: " .. tostring(passCount)
    lines[#lines + 1] = "- Failed: " .. tostring(#results - passCount)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Results"
    lines[#lines + 1] = ""

    for _, result in ipairs(results) do
        local status = result.ok and "PASS" or "FAIL"
        lines[#lines + 1] = string.format("- `%s` %s (%.2fms)", status, result.name, result.ms)
        if not result.ok then
            lines[#lines + 1] = "  - Error: `" .. tostring(result.err):gsub("\n", " ") .. "`"
        end
    end

    return table.concat(lines, "\n")
end

local report = buildReport()
print(report)

local hasFailure = false
for _, result in ipairs(results) do
    if not result.ok then
        hasFailure = true
        break
    end
end

os.exit(hasFailure and 1 or 0)
