package.path = package.path .. ";./?.lua"

local fireLane = require("ai_tournament.early_fire_lane")
local strategicQuestions = require("ai_tournament.strategic_questions")

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

local function stateWithRoute()
    return {
        gridSize = 8,
        commandHubs = {
            [1] = {row = 1, col = 1},
            [2] = {row = 1, col = 8}
        }
    }
end

local function ctx(opts)
    opts = opts or {}
    return {
        aiPlayer = 1,
        enemyPlayer = 2,
        cfg = {
            EARLY_FIRE_LANE_ENABLED = opts.enabled,
            EARLY_FIRE_LANE_ROUTE_MAX_SLACK = opts.maxSlack,
            EARLY_FIRE_LANE_MAX_SCORE = opts.maxScore,
            EARLY_FIRE_LANE_QUESTION_WEIGHT = opts.questionWeight,
            EARLY_FIRE_LANE_QUESTION_CAP = opts.questionCap,
            EARLY_DEAD_FIRE_LANE_PENALTY = opts.deadPenalty
        }
    }
end

local function cloudAt(row, col)
    return {
        name = "Cloudstriker",
        player = 1,
        row = row,
        col = col,
        atkRange = 3
    }
end

runTest("cloudstriker_without_route_line_is_dead_lane", function()
    local score = fireLane.score(stateWithRoute(), nil, ctx(), cloudAt(1, 1), {row = 1, col = 1}, {
        canAttackCellFrom = function()
            return false
        end
    })

    assertTrue(score.required == true, "Cloudstriker should require a real firing lane")
    assertTrue(score.deadLane == true, "Cloudstriker without route control should be marked dead")
    assertTrue(score.score == 0, "dead lane should not receive route-fire score")
end)

runTest("cloudstriker_with_route_line_scores", function()
    local score = fireLane.score(stateWithRoute(), nil, ctx(), cloudAt(1, 2), {row = 1, col = 2}, {
        canAttackCellFrom = function(_, _, _, fromCell, targetCell)
            return fromCell.row == targetCell.row and targetCell.col >= 4 and targetCell.col <= 5
        end
    })

    assertTrue(score.deadLane == false, "useful route control should not be dead")
    assertTrue(score.controlledCount > 0, "route cells should be counted")
    assertTrue(score.score > 0, "route cells should produce a positive score")
end)

runTest("disabled_flag_removes_fire_lane_effect", function()
    local score = fireLane.score(stateWithRoute(), nil, ctx({enabled = false}), cloudAt(1, 2), {row = 1, col = 2}, {
        canAttackCellFrom = function()
            return true
        end
    })

    assertTrue(score.score == 0, "disabled fire-lane policy should not score")
    assertTrue(score.deadLane == false, "disabled fire-lane policy should not penalize")
end)

runTest("strategic_question_rewards_useful_lane_and_penalizes_dead_lane", function()
    local useful = strategicQuestions.scoreCell({
        key = "1,2",
        row = 1,
        col = 2,
        strategicScore = 200,
        progress = 4,
        opportunity = {},
        risk = {},
        fireLaneScore = 160
    }, "expand", {ctx = ctx({questionWeight = 0.35, questionCap = 100, deadPenalty = 220})})
    local dead = strategicQuestions.scoreCell({
        key = "1,1",
        row = 1,
        col = 1,
        strategicScore = 200,
        progress = 4,
        opportunity = {},
        risk = {},
        deadFireLane = true
    }, "expand", {ctx = ctx({questionWeight = 0.35, questionCap = 100, deadPenalty = 220})})

    assertTrue(useful.value > dead.value, "dead lane should lose to useful lane in strategic question score")
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
