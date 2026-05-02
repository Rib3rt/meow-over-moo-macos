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
        error(string.format(
            "%s (expected=%s actual=%s)",
            message or "assertEquals failed",
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

local function makeState()
    return {
        phase = "actions",
        currentPlayer = 1,
        turnNumber = 10,
        currentTurn = 10,
        hasDeployedThisTurn = false,
        turnActionCount = 0,
        firstActionRangedAttack = nil,
        units = {
            {
                name = "Wingstalker",
                player = 1,
                row = 3,
                col = 3,
                currentHp = 3,
                startingHp = 3,
                hasActed = false,
                hasMoved = false,
                actionsUsed = 0
            },
            {
                name = "Commandant",
                player = 1,
                row = 1,
                col = 1,
                currentHp = 12,
                startingHp = 12,
                hasActed = false,
                hasMoved = false,
                actionsUsed = 0
            },
            {
                name = "Commandant",
                player = 2,
                row = 8,
                col = 8,
                currentHp = 12,
                startingHp = 12,
                hasActed = false,
                hasMoved = false,
                actionsUsed = 0
            }
        },
        commandHubs = {
            [1] = {row = 1, col = 1, currentHp = 12, startingHp = 12},
            [2] = {row = 8, col = 8, currentHp = 12, startingHp = 12}
        },
        neutralBuildings = {},
        unitsWithRemainingActions = {
            {name = "Wingstalker", player = 1, row = 3, col = 3}
        },
        supply = {
            [1] = {
                {name = "Bastion", currentHp = 6, startingHp = 6}
            },
            [2] = {
                {name = "Cloudstriker", currentHp = 4, startingHp = 4}
            }
        },
        guardAssignments = {
            ["Wingstalker:3,3"] = {row = 4, col = 3}
        }
    }
end

local function makeSequence()
    return {
        {
            type = "move",
            unit = {row = 3, col = 3},
            target = {row = 3, col = 4}
        },
        {
            type = "attack",
            unit = {row = 3, col = 4},
            target = {row = 8, col = 8}
        }
    }
end

runTest("simulation_cache_hits_on_second_call", function()
    local cacheModule = require("ai_tournament.cache")

    local ai = {
        simulateCalls = 0
    }
    function ai:simulateActionSequenceForPlayer(state, sequence, playerId)
        self.simulateCalls = self.simulateCalls + 1
        return {
            state = state,
            sequence = sequence,
            playerId = playerId,
            call = self.simulateCalls
        }
    end

    local ctx = {
        stats = {},
        turnEnumerator = {
            sequenceSignature = function(sequence)
                return "seq#" .. tostring(#(sequence or {}))
            end
        }
    }

    local cache = cacheModule.new(ctx)
    local state = makeState()
    local sequence = makeSequence()

    local first = cache.simulate(ai, state, sequence, 1, ctx)
    local second = cache.simulate(ai, state, sequence, 1, ctx)

    assertTrue(first ~= nil and second ~= nil, "expected simulated states")
    assertEquals(ai.simulateCalls, 1, "second call should hit simulation cache")
    assertEquals(cache.hits, 1, "expected one cache hit")
    assertEquals(cache.misses, 1, "expected one cache miss")
    assertEquals(ctx.stats.cacheHits, 1, "ctx.stats cacheHits should track hits")
    assertEquals(ctx.stats.cacheMisses, 1, "ctx.stats cacheMisses should track misses")
end)

runTest("feature_cache_hits_on_second_call", function()
    local cacheModule = require("ai_tournament.cache")

    local featureCalls = 0
    local ctx = {
        stats = {},
        evaluator = {
            buildStateFeatures = function(ai, state, playerId)
                featureCalls = featureCalls + 1
                return {
                    playerId = playerId,
                    unitCount = #(state.units or {}),
                    call = featureCalls,
                    ai = ai
                }
            end
        }
    }

    local cache = cacheModule.new(ctx)
    local state = makeState()
    local ai = {}

    local first = cache.features(ai, state, 1, ctx)
    local second = cache.features(ai, state, 1, ctx)

    assertTrue(first ~= nil and second ~= nil, "expected features output")
    assertEquals(featureCalls, 1, "second feature call should use cache")
    assertEquals(cache.hits, 1, "expected one feature cache hit")
    assertEquals(cache.misses, 1, "expected one feature cache miss")
end)

runTest("legal_action_cache_hits_on_second_call", function()
    local cacheModule = require("ai_tournament.cache")

    local legalCalls = 0
    local ai = {}
    function ai:collectLegalActions(state, opts)
        legalCalls = legalCalls + 1
        return {
            {
                type = "move",
                action = {
                    type = "move",
                    unit = {row = 3, col = 3},
                    target = {row = 3, col = 4}
                },
                state = state,
                opts = opts
            }
        }
    end

    local ctx = {stats = {}}
    local cache = cacheModule.new(ctx)
    local state = makeState()
    local opts = {
        includeMove = true,
        includeAttack = false,
        includeRepair = false,
        includeDeploy = false
    }

    local first = cache.legalActions(ai, state, 1, ctx, opts)
    local second = cache.legalActions(ai, state, 1, ctx, opts)

    assertEquals(legalCalls, 1, "second legal action call should use cache")
    assertTrue(first == second, "legal action cache should return stored entry table")
    assertEquals(cache.byKind.legal.hits, 1, "legal cache should record hit by kind")
    assertEquals(cache.byKind.legal.misses, 1, "legal cache should record miss by kind")
    assertEquals(ctx.stats.cacheLegalHits, 1, "ctx.stats should expose legal cache hits")
    assertEquals(ctx.stats.cacheLegalMisses, 1, "ctx.stats should expose legal cache misses")
end)

runTest("supply_snapshot_cache_hits_on_second_call", function()
    local cacheModule = require("ai_tournament.cache")

    local supplyCalls = 0
    local ctx = {
        stats = {},
        reserveModel = {
            snapshotSupplyForPlayer = function(ai, state, playerId)
                supplyCalls = supplyCalls + 1
                return {
                    ai = ai,
                    count = #((state.supply or {})[playerId] or {}),
                    playerId = playerId,
                    call = supplyCalls
                }
            end
        }
    }

    local cache = cacheModule.new(ctx)
    local state = makeState()
    local ai = {}

    local first = cache.supplySnapshot(ai, state, 1, ctx)
    local second = cache.supplySnapshot(ai, state, 1, ctx)

    assertTrue(first == second, "supply snapshot cache should return stored snapshot")
    assertEquals(supplyCalls, 1, "second supply snapshot call should use cache")
    assertEquals(cache.byKind.supply.hits, 1, "supply cache should record hit by kind")
    assertEquals(cache.byKind.supply.misses, 1, "supply cache should record miss by kind")
end)

runTest("threat_cache_hits_on_second_call", function()
    local cacheModule = require("ai_tournament.cache")

    local threatCalls = 0
    local ctx = {
        stats = {},
        threatModel = {
            analyzeHubThreatForPlayer = function(ai, state, playerToProtect, attackerPlayer)
                threatCalls = threatCalls + 1
                return {
                    ai = ai,
                    unitCount = #(state.units or {}),
                    playerToProtect = playerToProtect,
                    attackerPlayer = attackerPlayer,
                    call = threatCalls
                }
            end
        }
    }

    local cache = cacheModule.new(ctx)
    local state = makeState()
    local ai = {}

    local first = cache.threat(ai, state, 1, 2, ctx)
    local second = cache.threat(ai, state, 1, 2, ctx)

    assertTrue(first == second, "threat cache should return stored analysis")
    assertEquals(threatCalls, 1, "second threat call should use cache")
    assertEquals(cache.byKind.threat.hits, 1, "threat cache should record hit by kind")
    assertEquals(cache.byKind.threat.misses, 1, "threat cache should record miss by kind")
end)

runTest("cache_does_not_persist_between_decisions", function()
    local cacheModule = require("ai_tournament.cache")

    local ai = {
        simulateCalls = 0
    }
    function ai:simulateActionSequenceForPlayer(state, sequence, playerId)
        self.simulateCalls = self.simulateCalls + 1
        return {
            playerId = playerId,
            call = self.simulateCalls
        }
    end

    local state = makeState()
    local sequence = makeSequence()

    local cacheOne = cacheModule.new({stats = {}})
    local cacheTwo = cacheModule.new({stats = {}})

    local one = cacheOne.simulate(ai, state, sequence, 1)
    local two = cacheTwo.simulate(ai, state, sequence, 1)

    assertTrue(one ~= nil and two ~= nil, "expected valid simulation values")
    assertEquals(ai.simulateCalls, 2, "separate cache instances must not share simulation entries")
    assertEquals(cacheOne.misses, 1, "first decision cache should record first miss")
    assertEquals(cacheTwo.misses, 1, "second decision cache should record first miss")
    assertEquals(cacheOne.hits, 0, "first decision cache should not get shared hits")
    assertEquals(cacheTwo.hits, 0, "second decision cache should not get shared hits")
end)

runTest("extension_cache_runs_producer_once_per_key", function()
    local cacheModule = require("ai_tournament.cache")
    local cache = cacheModule.new()

    local producerCalls = 0
    local function producer()
        producerCalls = producerCalls + 1
        return {value = producerCalls}
    end

    local first = cache.extension("k1", producer)
    local second = cache.extension("k1", producer)

    assertTrue(first ~= nil and second ~= nil, "expected extension values")
    assertEquals(producerCalls, 1, "extension producer should run once for cached key")
    assertEquals(cache.hits, 1, "extension cache should record a hit")
    assertEquals(cache.misses, 1, "extension cache should record a miss")
end)

local function buildReport()
    local passCount = 0
    for _, result in ipairs(results) do
        if result.ok then
            passCount = passCount + 1
        end
    end

    local lines = {}
    lines[#lines + 1] = "# Tournament Cache Smoke"
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
