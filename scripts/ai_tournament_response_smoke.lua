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

local function newCtx(aiPlayer)
    local score = require("ai_tournament.score")
    local cache = require("ai_tournament.cache")
    local turnEnumerator = require("ai_tournament.turn_enumerator")
    local evaluator = require("ai_tournament.evaluator")
    local tacticalGate = require("ai_tournament.tactical_gate")
    local responseModel = require("ai_tournament.response_model")

    local ctx = {
        cfg = {
            USE_ENEMY_REPLY = true,
            MAX_FIRST_ACTIONS = 72,
            MAX_SECOND_ACTIONS = 36,
            MAX_OWN_CANDIDATES = 320,
            MAX_ENEMY_REPLY_CANDIDATES = 20
        },
        aiPlayer = aiPlayer,
        enemyPlayer = aiPlayer == 1 and 2 or 1,
        score = score,
        evaluator = evaluator,
        turnEnumerator = turnEnumerator,
        tacticalGate = tacticalGate,
        responseModel = responseModel,
        candidateBuckets = require("ai_tournament.candidate_buckets"),
        supplyPlanner = require("ai_tournament.supply_planner"),
        reserveModel = require("ai_tournament.reserve_model"),
        threatModel = require("ai_tournament.threat_model"),
        tacticalExtension = {
            evaluateReplyContinuation = function()
                return {
                    harmToUs = 0,
                    result = "neutral"
                }
            end
        },
        stats = {}
    }
    ctx.cache = cache.new(ctx)
    function ctx.shouldStop()
        return false
    end
    return ctx
end

local function containsDeployCandidate(candidates)
    for _, candidate in ipairs(candidates or {}) do
        if candidate and candidate.containsDeploy then
            return true
        end
    end
    return false
end

local function findLegalActionBySignature(ai, state, playerId, signature)
    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local legal = ai:collectLegalActions(state, {
        aiPlayer = playerId,
        includeMove = true,
        includeAttack = true,
        includeRepair = true,
        includeDeploy = false
    }) or {}
    for _, entry in ipairs(legal) do
        if entry and entry.action and fixtureLib.actionSignature(entry.action) == signature then
            return entry.action
        end
    end
    return nil
end

runTest("enemy_supply_present_absent_changes_deploy_reply_candidates", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local ai = mkAI(1)
    local response = require("ai_tournament.response_model")

    local presentState = fixtureLib.getFixture("enemy_supply_present").state
    local absentState = fixtureLib.getFixture("enemy_supply_absent").state

    local ctxPresent = newCtx(1)
    local enemyTurnPresent = ai:prepareStateForPlayerTurn(presentState, 2, {
        resetDeployment = true,
        resetActionCount = true
    })
    local repliesPresent = response.generateAdversarialReplies(ai, enemyTurnPresent, ctxPresent)
    assertTrue(
        containsDeployCandidate(repliesPresent) or (ctxPresent.stats.enemyReplyDeployCandidates or 0) > 0,
        "enemy supply present should allow deploy reply candidates"
    )

    local ctxAbsent = newCtx(1)
    local enemyTurnAbsent = ai:prepareStateForPlayerTurn(absentState, 2, {
        resetDeployment = true,
        resetActionCount = true
    })
    local repliesAbsent = response.generateAdversarialReplies(ai, enemyTurnAbsent, ctxAbsent)
    assertTrue((ctxAbsent.stats.enemyReplyDeployCandidates or 0) == 0, "enemy supply absent should generate zero deploy candidates")
    assertTrue(not containsDeployCandidate(repliesAbsent), "enemy supply absent should not produce deploy replies")
end)

runTest("worst_reply_detects_commandant_kill_line", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local evaluator = require("ai_tournament.evaluator")
    local ai = mkAI(1)
    local ctx = newCtx(1)

    local state = fixtureLib.buildBaseState({
        actingPlayer = 1,
        playerOneHub = {name = "Commandant", player = 1, row = 4, col = 4, currentHp = 3, startingHp = 12},
        playerTwoHub = {name = "Commandant", player = 2, row = 8, col = 8, currentHp = 12, startingHp = 12},
        units = {
            {
                name = "Crusher",
                player = 2,
                row = 4,
                col = 5,
                currentHp = 4,
                startingHp = 4,
                hasActed = false,
                hasMoved = false,
                actionsUsed = 0
            }
        }
    })

    local reply = ctx.responseModel.evaluateWorstReply(ai, state, ctx)
    assertTrue(reply and reply.afterEnemy, "expected scored enemy reply")
    assertTrue(evaluator.isCommandantDead(reply.afterEnemy, 1), "worst reply should kill our commandant")
    assertTrue((reply.summary and reply.summary.harmToUs or 0) >= 1000000, "commandant kill should have large harm")
end)

runTest("adversarial_reply_model_avoids_blunder_lines", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local evaluator = require("ai_tournament.evaluator")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    local state = fixtureLib.getFixture("immediate_commandant_defense").state

    local safeAction = findLegalActionBySignature(ai, state, 1, "attack:5,5->4,5")
    local unsafeAction = findLegalActionBySignature(ai, state, 1, "move:2,4->2,5")
    assertTrue(safeAction ~= nil and unsafeAction ~= nil, "fixture should expose safe and unsafe alternatives")

    local afterSafe = ai:simulateActionSequenceForPlayer(state, {safeAction}, 1, {})
    local afterUnsafe = ai:simulateActionSequenceForPlayer(state, {unsafeAction}, 1, {})

    local candidateSafe = {
        signature = "safe_defense",
        actions = {safeAction},
        containsDeploy = false,
        tacticalTags = {preventsImmediateLoss = true},
        buckets = {"anti_lethal"}
    }
    local candidateUnsafe = {
        signature = "unsafe_move",
        actions = {unsafeAction},
        containsDeploy = false,
        tacticalTags = {},
        buckets = {"positional_move"}
    }

    local replySafe = ctx.responseModel.evaluateWorstReply(ai, afterSafe, ctx)
    local replyUnsafe = ctx.responseModel.evaluateWorstReply(ai, afterUnsafe, ctx)

    assertTrue(replyUnsafe and replyUnsafe.afterEnemy and evaluator.isCommandantDead(replyUnsafe.afterEnemy, 1), "unsafe line should allow enemy commandant kill")

    local finalSafe = evaluator.scoreAfterEnemyReply(ai, state, afterSafe, replySafe, candidateSafe, ctx, nil)
    local finalUnsafe = evaluator.scoreAfterEnemyReply(ai, state, afterUnsafe, replyUnsafe, candidateUnsafe, ctx, nil)

    assertTrue(ctx.score.isBetter(finalSafe, finalUnsafe), "safe defense should outrank unsafe blunder after adversarial reply")
end)

runTest("reply_free_unit_loss_guard_penalizes_uncompensated_kill", function()
    ensureHeadlessGlobals()
    GAME.CURRENT.AI_PLAYER_NUMBER = 1

    local fixtureLib = require("scripts.ai_tournament_fixture_lib")
    local response = require("ai_tournament.response_model")
    local ai = mkAI(1)
    local ctx = newCtx(1)
    ctx.cfg.REPLY_FREE_UNIT_LOSS_GUARD_ENABLED = true
    ctx.cfg.REPLY_FREE_UNIT_LOSS_MIN_NET_VALUE = 20
    ctx.cfg.REPLY_FREE_UNIT_LOSS_COMPENSATION_RATIO = 0.8
    ctx.cfg.REPLY_FREE_UNIT_LOSS_BASE_PENALTY = 5000
    ctx.cfg.REPLY_FREE_UNIT_LOSS_NET_WEIGHT = 220
    ctx.cfg.REPLY_FREE_UNIT_LOSS_DAMAGE_COMPENSATION = 12
    ctx.cfg.REPLY_FREE_UNIT_LOSS_COMMANDANT_DAMAGE_COMPENSATION = 35

    local beforeEnemyTurn = fixtureLib.buildBaseState({
        actingPlayer = 2,
        currentPlayer = 2,
        units = {
            {name = "Crusher", player = 1, row = 4, col = 4, currentHp = 2, startingHp = 4},
            {name = "Cloudstriker", player = 2, row = 4, col = 7, currentHp = 4, startingHp = 4},
            {name = "Crusher", player = 2, row = 7, col = 7, currentHp = 2, startingHp = 4}
        }
    })
    local afterEnemy = fixtureLib.buildBaseState({
        actingPlayer = 1,
        currentPlayer = 1,
        units = {
            {name = "Cloudstriker", player = 2, row = 4, col = 7, currentHp = 4, startingHp = 4},
            {name = "Crusher", player = 2, row = 7, col = 7, currentHp = 2, startingHp = 4}
        }
    })

    local weakCompensation = {
        signature = "chip_then_free_loss",
        combatValue = {
            damage = 2,
            kills = 0,
            targetValue = 80,
            commandantDamage = 0
        }
    }
    local realTrade = {
        signature = "kill_for_kill",
        combatValue = {
            damage = 4,
            kills = 1,
            targetValue = 80,
            commandantDamage = 0
        }
    }

    local weakScore = response.scoreReplyForEnemy(
        ai,
        beforeEnemyTurn,
        afterEnemy,
        {signature = "enemy_kills_crusher", actions = {}},
        ctx,
        weakCompensation
    )
    assertTrue(
        weakScore.details
            and weakScore.details.freeUnitLossGuard
            and weakScore.details.freeUnitLossGuard.penalty > 0,
        "uncompensated reply kill should receive free-unit-loss penalty"
    )
    assertTrue(
        (ctx.stats.replyFreeUnitLossGuardHits or 0) > 0,
        "guard hit counter should increment for uncompensated reply kill"
    )

    local tradeScore = response.scoreReplyForEnemy(
        ai,
        beforeEnemyTurn,
        afterEnemy,
        {signature = "enemy_trades_crusher", actions = {}},
        ctx,
        realTrade
    )
    assertTrue(
        tradeScore.details
            and tradeScore.details.freeUnitLossGuard
            and tradeScore.details.freeUnitLossGuard.penalty == 0,
        "equivalent kill trade should not receive free-unit-loss penalty"
    )
    assertTrue(
        weakScore.harmToUs > tradeScore.harmToUs,
        "uncompensated loss should be scored as more harmful than equivalent trade"
    )
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Response Model Smoke"
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
