package.path = package.path .. ";./?.lua;./?/init.lua"

local passed = 0
local failed = 0

local function assertTrue(value, message)
    if not value then
        error(message or "expected true", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s expected=%s actual=%s", message or "assertEquals", tostring(expected), tostring(actual)), 2)
    end
end

local function runTest(name, fn)
    io.write(string.format("[deploy_runtime_smoke] %s ... ", name))
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok")
    else
        failed = failed + 1
        print("FAIL")
        print(err)
    end
end

local now = 10

_G.GAME = {
    CONSTANTS = {
        TILE_SIZE = 64
    }
}

_G.love = {
    timer = {
        getTime = function()
            return now
        end
    }
}

local function makeGrid()
    package.loaded.playGridClass = nil
    local playGridClass = require("playGridClass")
    local grid = setmetatable({
        rows = 8,
        cols = 8,
        cells = {},
        commandHubs = {},
        movingUnits = {},
        spawnBeams = {},
        rangedAttackEffects = {},
        commandHubZoomEffects = {},
        destructionEffects = {},
        rangedAttackEffectPool = {}
    }, playGridClass)

    for row = 1, grid.rows do
        grid.cells[row] = {}
        for col = 1, grid.cols do
            grid.cells[row][col] = {
                row = row,
                col = col,
                x = (col - 1) * GAME.CONSTANTS.TILE_SIZE,
                y = (row - 1) * GAME.CONSTANTS.TILE_SIZE,
                unit = nil
            }
        end
    end

    grid.startScreenShake = function() end
    grid.createImpactEffect = function() end
    grid.playEarthquakeSound = function() end

    return grid
end

runTest("beam_deploy_keeps_visual_timing_and_places_during_beam_update", function()
    local grid = makeGrid()
    local unit = {
        name = "Earthstalker",
        player = 1,
        health = 10,
        attack = 4
    }

    local beam = grid:createBeamEffect(2, 7, unit)
    assertTrue(beam ~= nil, "beam should be created")

    assertEquals(grid:getUnitAt(2, 7), nil, "deployed unit should not appear before beam placement timing")
    assertEquals(beam.unitToPlace, unit, "beam should keep the unit until placement timing")

    now = beam.startTime + beam.silhouetteTime + 0.01
    grid:updateBeamEffects(0.016, now)
    assertEquals(grid:getUnitAt(2, 7), nil, "unit should wait for the landing placement delay")

    now = beam.startTime + beam.unitPlaceTime + 0.01
    grid:updateBeamEffects(0.016, now)

    local placed = grid:getUnitAt(2, 7)
    assertTrue(placed ~= nil, "deployed unit should be visible after beam placement timing")
    assertEquals(placed.name, "Earthstalker", "placed unit name")
    assertEquals(placed.player, 1, "placed unit player")
    assertEquals(beam.unitToPlace, nil, "beam should not keep a duplicate unit after placement")
end)

runTest("spawn_beams_block_animation_progression", function()
    local grid = makeGrid()
    assertTrue(not grid:hasActiveAnimations(), "fresh grid should have no active animations")

    grid:createBeamEffect(2, 7, {name = "Wingstalker", player = 2})
    assertTrue(grid:hasActiveAnimations(), "active spawn beam should count as animation")

    grid.spawnBeams = {}
    assertTrue(not grid:hasActiveAnimations(), "cleared spawn beams should unblock animations")

    grid.rangedAttackEffects = {{fromRow = 1, fromCol = 1}}
    assertTrue(grid:hasActiveAnimations(), "ranged attack effects should count as animation")
end)

runTest("action_animation_buckets_block_ai_progression", function()
    local grid = makeGrid()

    local buckets = {
        movingUnits = {{progress = 0.2}},
        activeEffects = {{type = "buildingPlacement"}},
        rangedAttackEffects = {{startTime = 1, duration = 0.5}},
        commandHubZoomEffects = {{startTime = 1, duration = 0.5}},
        commandHubScanEffects = {{startTime = 1, duration = 0.5}},
        destructionEffects = {{type = "particles"}},
        teslaStrikeEffects = {{startTime = 1, duration = 0.5}},
        impactEffects = {{startTime = 1, duration = 0.5}}
    }

    for bucketName, value in pairs(buckets) do
        grid = makeGrid()
        grid[bucketName] = value
        assertTrue(grid:hasActiveAnimations(), bucketName .. " should count as animation")
    end
end)

runTest("ranged_attack_effects_clear_from_update_without_waiting_for_draw", function()
    local grid = makeGrid()
    grid.rangedAttackEffects = {{
        fromRow = 1,
        fromCol = 1,
        toRow = 1,
        toCol = 2,
        attackType = "default",
        startTime = 1,
        duration = 0.5
    }}

    now = 1.25
    grid:updateRangedAttackEffects(0.016, now)
    assertTrue(grid:hasActiveAnimations(), "active ranged attack should remain before duration")

    now = 1.6
    grid:updateRangedAttackEffects(0.016, now)
    assertTrue(not grid:hasActiveAnimations(), "completed ranged attack should clear during update")
end)

if failed > 0 then
    error(string.format("deploy_runtime_smoke failed: %d/%d", failed, passed + failed))
end

print(string.format("[deploy_runtime_smoke] passed %d/%d", passed, passed + failed))
