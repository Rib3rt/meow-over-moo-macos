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
        }
    }

    _G.DEBUG = _G.DEBUG or {}
    DEBUG.AI = false

    _G.GAME = _G.GAME or {}
    GAME.CONSTANTS = GAME.CONSTANTS or {}
    GAME.CONSTANTS.GRID_SIZE = GAME.CONSTANTS.GRID_SIZE or 8
    GAME.CONSTANTS.MAX_ACTIONS_PER_TURN = GAME.CONSTANTS.MAX_ACTIONS_PER_TURN or 2
    GAME.CURRENT = GAME.CURRENT or {}
    GAME.CURRENT.TURN = GAME.CURRENT.TURN or 11
    GAME.CURRENT.AI_PLAYER_NUMBER = GAME.CURRENT.AI_PLAYER_NUMBER or 1
end

local function mkAI(factionId)
    local AI = require("ai")
    local ai = AI.new({factionId = factionId})
    ai.grid = {
        getUnitAt = function()
            return nil
        end
    }
    ai.calculateDamage = function(_, attacker)
        return attacker and attacker.atkDamage or 1
    end
    return ai
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
        move = 2,
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

local function stateWith(units, neutralBuildings)
    return {
        currentPlayer = 1,
        currentTurn = 11,
        turnNumber = 11,
        gridSize = 8,
        units = units or {},
        neutralBuildings = neutralBuildings or {},
        commandHubs = {
            [1] = {name = "Commandant", player = 1, row = 1, col = 2, currentHp = 12, startingHp = 12},
            [2] = {name = "Commandant", player = 2, row = 8, col = 7, currentHp = 12, startingHp = 12}
        },
        supply = {
            [1] = {},
            [2] = {}
        }
    }
end

local function ctx()
    return {
        aiPlayer = 1,
        enemyPlayer = 2,
        phase = {name = "mid"},
        cfg = {
            STRATEGIC_PERSONALITY = "neutral_base"
        },
        stats = {}
    }
end

local function containsCell(list, key)
    for _, cell in ipairs(list or {}) do
        if cell.key == key then
            return true
        end
    end
    return false
end

runTest("mid_position_map_keeps_attack_contested_cells", function()
    ensureHeadlessGlobals()
    local midMap = require("ai_tournament.mid_position_map")
    local ai = mkAI(1)
    local state = stateWith({
        unit("Crusher", 1, 4, 3),
        unit("Crusher", 2, 4, 5)
    })

    local result = midMap.build(ai, state, ctx(), {limit = 8})
    local cell = result.byKey["4,4"]
    assertTrue(cell ~= nil, "expected contested center cell")
    assertTrue(cell.status == "contested_pressure", "contested cell should stay available to mid")
    assertTrue(cell.attackContested == true, "cell should expose attack contest")
    assertTrue(cell.directlyAttackableByEnemy == true, "mid must see enemy direct threat instead of hiding it")
    assertTrue(containsCell(result.contestedTop, "4,4"), "contested cell should be summarized")
end)

runTest("mid_position_map_exposes_attackable_enemy_targets", function()
    ensureHeadlessGlobals()
    local midMap = require("ai_tournament.mid_position_map")
    local ai = mkAI(1)
    local state = stateWith({
        unit("Crusher", 1, 4, 4),
        unit("Earthstalker", 2, 4, 5)
    })

    local result = midMap.build(ai, state, ctx(), {limit = 8})
    local cell = result.byKey["4,5"]
    assertTrue(cell ~= nil, "expected enemy occupied cell")
    assertTrue(cell.status == "enemy_occupied", "enemy unit should be classified as an occupied target")
    assertTrue(cell.attackableEnemy == true, "adjacent enemy should be an attack target")
    assertTrue(containsCell(result.attackTargets, "4,5"), "attack target should be in attackTargets")
end)

runTest("mid_position_map_keeps_blocked_cells_low", function()
    ensureHeadlessGlobals()
    local midMap = require("ai_tournament.mid_position_map")
    local ai = mkAI(1)
    local state = stateWith({
        unit("Crusher", 1, 4, 3),
        unit("Crusher", 2, 4, 5)
    }, {
        {name = "Rock", row = 4, col = 4, currentHp = 5, startingHp = 5}
    })

    local result = midMap.build(ai, state, ctx(), {limit = 8})
    local cell = result.byKey["4,4"]
    assertTrue(cell ~= nil, "blocked cell should still be inspectable in the map")
    assertTrue(cell.status == "blocked", "rock cell should be blocked")
    assertTrue(cell.value < 0, "blocked cell should not look like a useful mid target")
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
    print(string.format("ai_tournament_mid_position_map_smoke failed: %d/%d", failed, #results))
    os.exit(1)
end

print(string.format("ai_tournament_mid_position_map_smoke passed: %d/%d", #results, #results))
