local stateEngine = require("scenario_tooling.state_engine")
local rulesKernel = require("scenario_tooling.rules_kernel")
local redPolicy = require("scenario_tooling.red_policy")

local okDefensiveDomain, defensiveDomain = pcall(require, "scenario_tooling.defensive_domain")
if not okDefensiveDomain then
    defensiveDomain = nil
end

local M = {
    VERSION = "scenario_solver.v1"
}

local DEFAULT_MAX_PLIES_CAP = 24
local DEFAULT_MAX_NODES = 50000
local BLUE = 1
local RED = 2
local BLUE_PASS_PROOF_CACHE = {}

local function stableString(v)
    if v == nil then
        return ""
    end
    if type(v) == "number" then
        return string.format("%.12g", v)
    end
    return tostring(v)
end

local function shallowCopyArray(arr)
    local out = {}
    if type(arr) ~= "table" then
        return out
    end
    for i = 1, #arr do
        out[i] = arr[i]
    end
    return out
end

local function appendAction(line, action)
    local out = shallowCopyArray(line)
    out[#out + 1] = action
    return out
end

local function prependAction(action, line)
    local out = { action }
    local source = type(line) == "table" and line or {}
    for i = 1, #source do
        out[#out + 1] = source[i]
    end
    return out
end

local function lineLength(line)
    return type(line) == "table" and #line or 0
end

local BLUE_ACTION_ORDER = {
    attack = 1,
    move = 2,
    end_turn = 3
}

local function actionMatches(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if a.id and b.id and a.id == b.id then
        return true
    end
    if a.type ~= b.type then
        return false
    end
    if stableString(a.actorId) ~= stableString(b.actorId) then
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

local function prioritizePreferredAction(actions, preferredAction)
    if type(preferredAction) ~= "table" then
        return actions
    end
    table.sort(actions, function(a, b)
        local ap = actionMatches(a, preferredAction)
        local bp = actionMatches(b, preferredAction)
        if ap ~= bp then
            return ap
        end
        return false
    end)
    return actions
end

local function orderedBlueActions(state, preferredAction)
    local actions = stateEngine.getLegalActions(state)
    table.sort(actions, function(a, b)
        local ar = BLUE_ACTION_ORDER[a.type or ""] or 99
        local br = BLUE_ACTION_ORDER[b.type or ""] or 99
        if ar ~= br then
            return ar < br
        end
        return stableString(a.id) < stableString(b.id)
    end)
    return prioritizePreferredAction(actions, preferredAction)
end

local function defaultMaxPlies(state)
    local s = stateEngine.normalize(state)
    local turnLimit = tonumber(s.turnLimit) or 1
    local scenarioTurn = tonumber(s.scenarioTurn) or 1
    local maxActionsPerTurn = tonumber(s.maxActionsPerTurn) or 2
    local turnsLeft = turnLimit - scenarioTurn + 1
    if turnsLeft < 1 then
        turnsLeft = 1
    end
    local plies = turnsLeft * ((maxActionsPerTurn + 1) * 2)
    if plies > DEFAULT_MAX_PLIES_CAP then
        plies = DEFAULT_MAX_PLIES_CAP
    end
    return plies
end

local function resolveDomain(opts)
    local d = opts and opts.proofDomain or "all_legal"
    if d ~= "all_legal" and d ~= "defensive" then
        return "all_legal"
    end
    return d
end

local function normalizeActionsFromDecisions(decisions)
    local out = {}
    if type(decisions) ~= "table" then
        return out
    end
    for i = 1, #decisions do
        local d = decisions[i]
        if type(d) == "table" and d.decision == "include" and type(d.redAction) == "table" then
            out[#out + 1] = d.redAction
        end
    end
    return out
end

local function classifyDefensive(state, opts)
    if not defensiveDomain then
        return nil, nil, { solverStatus = "unknown", reason = "defensive_domain_unavailable" }
    end
    if type(defensiveDomain.includedActions) == "function" then
        local actions, decisions, summary = defensiveDomain.includedActions(state, opts or {})
        if type(actions) ~= "table" then
            actions = {}
        end
        return actions, decisions, summary or {}
    end
    if type(defensiveDomain.classifyAll) == "function" then
        local decisions, summary = defensiveDomain.classifyAll(state, opts or {})
        local actions = normalizeActionsFromDecisions(decisions)
        return actions, decisions, summary or {}
    end
    return nil, nil, { solverStatus = "unknown", reason = "defensive_domain_api_missing" }
end

local function getRedActions(state, opts, domain)
    if domain == "all_legal" then
        return stateEngine.getLegalActions(state), nil, nil
    end
    local actions, decisions, summary = classifyDefensive(state, opts)
    return actions or {}, decisions, summary
end

local function cacheKey(stateHash, pliesLeft, player, domain)
    return table.concat({ stateHash, tostring(pliesLeft), tostring(player), domain }, "|")
end

local function analyzeTerminal(state)
    local outcome = stateEngine.evaluateOutcome(state)
    if type(outcome) ~= "table" then
        return nil, outcome
    end
    if outcome.status == "blue_win" then
        return "forced_win", outcome
    end
    if outcome.status == "blue_loss" or outcome.status == "red_win" or outcome.status == "draw" then
        return "unsolved", outcome
    end
    return nil, outcome
end

local function resetBlueForNextTurnWithoutRed(state)
    local s = stateEngine.cloneState(stateEngine.normalize(state))
    s.currentPlayer = BLUE
    s.scenarioTurn = (tonumber(s.scenarioTurn) or 1) + 1
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

local function canonicalProofAction(action)
    if type(action) ~= "table" then
        return {}
    end
    local out = {
        type = action.type,
        actorId = action.actorId,
        targetId = action.targetId,
        id = action.id
    }
    if type(action.to) == "table" then
        out.to = { row = tonumber(action.to.row), col = tonumber(action.to.col) }
    end
    if type(action.from) == "table" then
        out.from = { row = tonumber(action.from.row), col = tonumber(action.from.col) }
    end
    if type(action.targetCell) == "table" then
        out.targetCell = { row = tonumber(action.targetCell.row), col = tonumber(action.targetCell.col) }
    end
    return out
end

local function appendCanonicalProofAction(path, action)
    local out = shallowCopyArray(path)
    out[#out + 1] = canonicalProofAction(action)
    return out
end

local function canonicalProofLine(line)
    local out = {}
    for i = 1, #(line or {}) do
        out[#out + 1] = canonicalProofAction(line[i])
    end
    return out
end

local function bluePassProofSearch(state, opts)
    opts = type(opts) == "table" and opts or {}
    local maxNodes = tonumber(opts.maxNodes) or DEFAULT_MAX_NODES
    if maxNodes <= 0 then
        maxNodes = DEFAULT_MAX_NODES
    end
    local stats = {
        nodes = 0,
        maxNodes = maxNodes,
        proofMode = "blue_even_if_red_passes"
    }
    local visited = {}
    local maxActionsPerTurn = tonumber(state and state.maxActionsPerTurn) or 2

    local function visitKey(s, turnsRemaining)
        return table.concat({
            stateEngine.stateHash(s),
            tostring(turnsRemaining),
            tostring(s.currentPlayer),
            tostring(s.turnActions or 0)
        }, "|")
    end

    local function searchBlue(cursor, path)
        local s = stateEngine.normalize(cursor)
        stats.nodes = stats.nodes + 1
        if stats.nodes > maxNodes then
            return {
                status = "unknown",
                reason = "max_nodes_exhausted",
                stats = stats
            }
        end

        local terminalStatus, outcome = analyzeTerminal(s)
        if terminalStatus == "forced_win" then
            return {
                status = "blue_win_possible_with_red_pass",
                witness = path,
                outcome = outcome,
                stats = stats
            }
        end
        if terminalStatus == "unsolved" then
            return nil
        end

        if tonumber(s.currentPlayer) == RED then
            local nextBlue = resetBlueForNextTurnWithoutRed(s)
            if (tonumber(nextBlue.scenarioTurn) or 1) > (tonumber(nextBlue.turnLimit) or 10) then
                return nil
            end
            return searchBlue(nextBlue, path)
        end

        local scenarioTurn = tonumber(s.scenarioTurn) or 1
        local turnLimit = tonumber(s.turnLimit) or scenarioTurn
        if scenarioTurn > turnLimit then
            return nil
        end

        local key = visitKey(s, turnLimit - scenarioTurn + 1)
        if visited[key] then
            return nil
        end
        visited[key] = true

        local legal = orderedBlueActions(s, nil)
        local i
        for i = 1, #legal do
            local action = legal[i]
            if action.type ~= "end_turn" then
                local nextState = stateEngine.applyAction(s, action)
                local found = searchBlue(nextState, appendCanonicalProofAction(path, action))
                if found then
                    return found
                end
            end
        end

        if scenarioTurn < turnLimit then
            local nextBlue = resetBlueForNextTurnWithoutRed(s)
            local found = searchBlue(nextBlue, appendCanonicalProofAction(path, { type = "end_turn" }))
            if found then
                return found
            end
        end
        return nil
    end

    local normalized = stateEngine.normalize(state)
    if tonumber(normalized.currentPlayer) ~= BLUE then
        normalized = resetBlueForNextTurnWithoutRed(normalized)
    end
    normalized.maxActionsPerTurn = maxActionsPerTurn
    local cacheKeyText = table.concat({
        stateEngine.stateHash(normalized),
        tostring(normalized.scenarioTurn),
        tostring(normalized.turnLimit),
        tostring(normalized.turnActions or 0),
        tostring(maxNodes)
    }, "|")
    if BLUE_PASS_PROOF_CACHE[cacheKeyText] then
        local cached = stateEngine.cloneState(BLUE_PASS_PROOF_CACHE[cacheKeyText])
        cached.cacheHit = true
        return cached
    end

    local found = searchBlue(normalized, {})
    if found then
        BLUE_PASS_PROOF_CACHE[cacheKeyText] = stateEngine.cloneState(found)
        return found
    end
    local proven = {
        status = "no_blue_win_even_with_red_pass",
        proven = true,
        stats = stats,
        stateHash = stateEngine.stateHash(normalized)
    }
    BLUE_PASS_PROOF_CACHE[cacheKeyText] = stateEngine.cloneState(proven)
    return proven
end

local function search(state, pliesLeft, opts, ctx, plyIndex)
    plyIndex = plyIndex or 1
    local normalized = stateEngine.normalize(state)
    local stateHash = normalized.stateHash or stateEngine.stateHash(normalized)
    local player = normalized.currentPlayer
    local domain = ctx.proofDomain
    local key = cacheKey(stateHash, pliesLeft, player, domain)
    local cached = ctx.cache[key]
    if cached then
        ctx.stats.cacheHits = ctx.stats.cacheHits + 1
        return cached
    end
    ctx.stats.nodes = ctx.stats.nodes + 1
    if ctx.maxNodes and ctx.stats.nodes > ctx.maxNodes then
        return {
            status = "unknown",
            winningLine = {},
            refutations = {},
            earliestWinRound = nil,
            defensiveDomainDecisions = nil,
            reason = "max_nodes_exhausted"
        }
    end

    local terminalStatus, terminalOutcome = analyzeTerminal(normalized)
    if terminalStatus then
        local terminal = {
            status = terminalStatus,
            winningLine = {},
            refutations = {},
            earliestWinRound = terminalStatus == "forced_win" and normalized.scenarioTurn or nil,
            defensiveDomainDecisions = nil,
            outcome = terminalOutcome
        }
        ctx.cache[key] = terminal
        return terminal
    end

    if pliesLeft <= 0 then
        local timed = {
            status = "unknown",
            winningLine = {},
            refutations = {},
            earliestWinRound = nil,
            defensiveDomainDecisions = nil,
            reason = "max_plies_exhausted"
        }
        ctx.cache[key] = timed
        return timed
    end

    if player == 1 then
        ctx.stats.blueNodes = ctx.stats.blueNodes + 1
        local preferredAction = type(opts.preferredLine) == "table" and opts.preferredLine[plyIndex] or nil
        local legal = orderedBlueActions(normalized, preferredAction)
        local sawUnknown = false
        local losingMoves = {}
        local bestUnknown = nil

        for i = 1, #legal do
            local action = legal[i]
            ctx.stats.expandedActions = ctx.stats.expandedActions + 1
            local nextState = stateEngine.applyAction(normalized, action)
            local child = search(nextState, pliesLeft - 1, opts, ctx, plyIndex + 1)
            if child.status == "forced_win" then
                local line = prependAction(action, child.winningLine)
                local solved = {
                    status = "forced_win",
                    winningLine = line,
                    refutations = child.refutations or {},
                    earliestWinRound = child.earliestWinRound,
                    defensiveDomainDecisions = child.defensiveDomainDecisions
                }
                ctx.cache[key] = solved
                return solved
            end
            if child.status == "unknown" then
                sawUnknown = true
                if not bestUnknown then
                    bestUnknown = child
                end
            else
                losingMoves[#losingMoves + 1] = action
            end
        end

        if sawUnknown then
            local unresolved = {
                status = "unknown",
                winningLine = {},
                refutations = bestUnknown and bestUnknown.refutations or {},
                earliestWinRound = nil,
                defensiveDomainDecisions = bestUnknown and bestUnknown.defensiveDomainDecisions or nil,
                losingFirstMoves = losingMoves
            }
            ctx.cache[key] = unresolved
            return unresolved
        end

        local failed = {
            status = "unsolved",
            winningLine = {},
            refutations = {},
            earliestWinRound = nil,
            defensiveDomainDecisions = nil,
            losingFirstMoves = losingMoves
        }
        ctx.cache[key] = failed
        return failed
    end

    ctx.stats.redNodes = ctx.stats.redNodes + 1
    local redActions, decisions, summary = getRedActions(normalized, opts, domain)
    local preferredAction = type(opts.preferredLine) == "table" and opts.preferredLine[plyIndex] or nil
    prioritizePreferredAction(redActions, preferredAction)
    if domain == "defensive" and type(summary) == "table" and summary.solverStatus == "unknown" then
        local unknownDomain = {
            status = "unknown",
            winningLine = {},
            refutations = {},
            earliestWinRound = nil,
            defensiveDomainDecisions = decisions or {},
            reason = summary.reason or "defensive_domain_unknown"
        }
        ctx.cache[key] = unknownDomain
        return unknownDomain
    end

    local sawUnknown = false
    local collectedDecisions = decisions or nil
    local bestUnknown = nil
    local representativeForcedLine = nil
    local latestForcedWinRound = nil
    for i = 1, #redActions do
        local action = redActions[i]
        ctx.stats.expandedActions = ctx.stats.expandedActions + 1
        local nextState = stateEngine.applyAction(normalized, action)
        local child = search(nextState, pliesLeft - 1, opts, ctx, plyIndex + 1)
        if child.status == "unsolved" then
            local refLine = { action }
            for j = 1, #(child.winningLine or {}) do
                refLine[#refLine + 1] = child.winningLine[j]
            end
            local refuted = {
                status = "unsolved",
                winningLine = {},
                refutations = {
                    {
                        redResponse = action,
                        line = refLine,
                        childStatus = child.status
                    }
                },
                earliestWinRound = nil,
                defensiveDomainDecisions = collectedDecisions
            }
            ctx.cache[key] = refuted
            return refuted
        end
        if child.status == "unknown" then
            sawUnknown = true
            if not bestUnknown then
                bestUnknown = child
            end
        elseif child.status == "forced_win" then
            local forcedLine = prependAction(action, child.winningLine)
            if not representativeForcedLine then
                representativeForcedLine = forcedLine
            end
            local childRound = tonumber(child.earliestWinRound)
            if childRound then
                if not latestForcedWinRound or childRound > latestForcedWinRound then
                    latestForcedWinRound = childRound
                end
            end
        end
    end

    if sawUnknown then
        local unresolved = {
            status = "unknown",
            winningLine = {},
            refutations = bestUnknown and bestUnknown.refutations or {},
            earliestWinRound = nil,
            defensiveDomainDecisions = collectedDecisions or (bestUnknown and bestUnknown.defensiveDomainDecisions or nil)
        }
        ctx.cache[key] = unresolved
        return unresolved
    end

    local survived = {
        status = "forced_win",
        winningLine = representativeForcedLine or {},
        refutations = {},
        earliestWinRound = latestForcedWinRound,
        defensiveDomainDecisions = collectedDecisions
    }
    ctx.cache[key] = survived
    return survived
end

local function buildCertificate(initialState, result, opts, ctx)
    local domain = resolveDomain(opts or {})
    local cert = {
        seed = opts and opts.seed or nil,
        solverVersion = M.VERSION,
        rulesKernelVersion = rulesKernel.VERSION,
        stateEngineVersion = stateEngine.VERSION,
        redPolicyVersion = redPolicy and redPolicy.VERSION or nil,
        redPolicyHash = redPolicy and redPolicy.POLICY_HASH or nil,
        defensiveDomainVersion = defensiveDomain and defensiveDomain.VERSION or nil,
        defensiveDomainHash = defensiveDomain and defensiveDomain.DOMAIN_HASH or nil,
        proofDomain = domain,
        initialStateHash = stateEngine.stateHash(initialState),
        searchResult = result.status,
        winningLine = result.winningLine or {},
        refutations = result.refutations or {},
        falseLines = {}
    }
    cert.stats = ctx.stats
    return cert
end

function M.isScenarioOnly()
    return true
end

function M.proveNoBlueWinEvenIfRedPasses(state, opts)
    return bluePassProofSearch(state, opts or {})
end

function M.solve(state, opts)
    local normalized = stateEngine.normalize(state)
    local maxPlies = opts and tonumber(opts.maxPlies) or defaultMaxPlies(normalized)
    if maxPlies < 0 then
        maxPlies = 0
    end
    local proofDomain = resolveDomain(opts or {})
    local maxNodes = tonumber(opts and opts.maxNodes) or DEFAULT_MAX_NODES
    if maxNodes <= 0 then
        maxNodes = nil
    end
    local ctx = {
        proofDomain = proofDomain,
        maxNodes = maxNodes,
        cache = {},
        stats = {
            nodes = 0,
            blueNodes = 0,
            redNodes = 0,
            expandedActions = 0,
            cacheHits = 0,
            maxPlies = maxPlies,
            maxNodes = maxNodes,
            proofDomain = proofDomain
        }
    }

    local result = search(normalized, maxPlies, opts or {}, ctx, 1)
    local proof = {
        status = result.status or "unknown",
        winningLine = canonicalProofLine(result.winningLine or {}),
        losingFirstMoves = result.losingFirstMoves or {},
        earliestWinRound = result.earliestWinRound,
        refutations = result.refutations or {},
        reason = result.reason,
        stats = ctx.stats,
        proofCertificate = nil
    }
    if proofDomain == "defensive" then
        proof.defensiveDomainDecisions = result.defensiveDomainDecisions or {}
    end
    proof.proofCertificate = buildCertificate(normalized, proof, opts or {}, ctx)
    return proof
end

function M.proveFalseLine(state, actions, opts)
    local normalized = stateEngine.normalize(state)
    local replay = {
        initialStateHash = stateEngine.stateHash(normalized),
        applied = {}
    }
    local cursor = normalized
    local line = type(actions) == "table" and actions or {}
    for i = 1, #line do
        local action = line[i]
        local legal = stateEngine.getLegalActions(cursor)
        local found = false
        local chosen = nil
        for j = 1, #legal do
            if legal[j].id == action.id or (legal[j].type == action.type and stableString(legal[j].actorId) == stableString(action.actorId)) then
                if action.type ~= "move" or (action.to and legal[j].to and action.to.row == legal[j].to.row and action.to.col == legal[j].to.col) then
                    if action.type ~= "attack" or stableString(action.targetId) == stableString(legal[j].targetId) then
                        found = true
                        chosen = legal[j]
                        break
                    end
                end
            end
        end
        if not found then
            return {
                status = "false_line_proven",
                reason = "illegal_action_in_line",
                replay = replay,
                proof = {
                    failingIndex = i,
                    action = action
                }
            }
        end
        cursor = stateEngine.applyAction(cursor, chosen)
        replay.applied[#replay.applied + 1] = {
            action = chosen,
            stateHash = stateEngine.stateHash(cursor)
        }
    end

    local redPassProof = M.proveNoBlueWinEvenIfRedPasses(cursor, opts or {})
    if redPassProof.status == "no_blue_win_even_with_red_pass" then
        return {
            status = "false_line_proven",
            reason = "no_blue_win_even_with_red_pass",
            replay = replay,
            proof = redPassProof
        }
    end
    if redPassProof.status == "unknown" then
        return {
            status = "unknown",
            reason = "red_pass_bound_unknown",
            replay = replay,
            proof = redPassProof
        }
    end

    local continuation = M.solve(cursor, opts or {})
    if continuation.status == "forced_win" then
        return {
            status = "false_line_not_proven",
            reason = "continuation_forced_win",
            replay = replay,
            proof = continuation
        }
    end
    if continuation.status == "unknown" then
        return {
            status = "unknown",
            reason = "continuation_unknown",
            replay = replay,
            proof = continuation
        }
    end
    return {
        status = "false_line_proven",
        reason = "continuation_not_forced_win",
        replay = replay,
        proof = continuation
    }
end

return M
