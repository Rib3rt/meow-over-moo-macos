package.path = package.path .. ";./?.lua"

local tollRoute = require("ai_tournament.early_position_toll_route")

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

local function hub(row, col)
    return {row = row, col = col}
end

local function ctx(opts)
    opts = opts or {}
    return {
        aiPlayer = 1,
        enemyPlayer = 2,
        cfg = {
            PIPELINE_V2_EARLY_TOLL_ROUTE_ENABLED = opts.enabled,
            PIPELINE_V2_EARLY_TOLL_ROUTE_MAX_SLACK = opts.maxSlack,
            PIPELINE_V2_EARLY_TOLL_ROUTE_WEIGHT = opts.weight
        }
    }
end

local function stateWithHubs(own, enemy)
    return {
        commandHubs = {
            [1] = own,
            [2] = enemy
        }
    }
end

runTest("advanced_route_cell_scores_above_backline_route_cell", function()
    local state = stateWithHubs(hub(4, 1), hub(4, 8))
    local route = {ownHub = state.commandHubs[1], enemyHub = state.commandHubs[2], distance = 7}
    local backline = tollRoute.score(state, ctx(), route, {row = 4, col = 2})
    local advanced = tollRoute.score(state, ctx(), route, {row = 4, col = 6})

    assertTrue(advanced.value > backline.value, "advanced route control should gain more field value")
end)

runTest("fast_route_cell_scores_above_wide_detour_cell", function()
    local state = stateWithHubs(hub(4, 1), hub(4, 8))
    local route = {ownHub = state.commandHubs[1], enemyHub = state.commandHubs[2], distance = 7}
    local direct = tollRoute.score(state, ctx({maxSlack = 2}), route, {row = 4, col = 5})
    local detour = tollRoute.score(state, ctx({maxSlack = 2}), route, {row = 1, col = 5})

    assertTrue(direct.value > detour.value, "direct fastest-route cell should outrank a wide detour")
    assertTrue(direct.routeSlack < detour.routeSlack, "direct route should have lower slack")
end)

runTest("covered_cell_charges_more_toll", function()
    local state = stateWithHubs(hub(4, 1), hub(4, 8))
    local route = {ownHub = state.commandHubs[1], enemyHub = state.commandHubs[2], distance = 7}
    local plain = tollRoute.score(state, ctx(), route, {row = 4, col = 5})
    local covered = tollRoute.score(state, ctx(), route, {
        row = 4,
        col = 5,
        coveredIfOccupied = true,
        attackInfluence = {
            us = {active = true, count = 1},
            enemy = {active = false, count = 0}
        }
    })

    assertTrue(covered.value > plain.value, "coverage should increase the toll paid by the opponent")
    assertTrue(covered.tollPressure > plain.tollPressure, "coverage should be visible in toll pressure")
end)

runTest("dead_fire_lane_reduces_toll_route_value", function()
    local state = stateWithHubs(hub(4, 1), hub(4, 8))
    local route = {ownHub = state.commandHubs[1], enemyHub = state.commandHubs[2], distance = 7}
    local useful = tollRoute.score(state, ctx(), route, {
        row = 4,
        col = 5,
        fireLaneScore = 160
    })
    local dead = tollRoute.score(state, ctx(), route, {
        row = 4,
        col = 5,
        deadFireLane = true
    })

    assertTrue(useful.value > dead.value, "dead firing lanes should not look like useful toll cells")
    assertTrue(useful.fireLaneScore > 0, "useful firing lane score should be surfaced")
end)

runTest("flag_can_disable_toll_route_score", function()
    local state = stateWithHubs(hub(4, 1), hub(4, 8))
    local route = {ownHub = state.commandHubs[1], enemyHub = state.commandHubs[2], distance = 7}
    local score = tollRoute.score(state, ctx({enabled = false}), route, {row = 4, col = 5})

    assertTrue(score.value == 0, "disabled toll route should contribute no score")
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
