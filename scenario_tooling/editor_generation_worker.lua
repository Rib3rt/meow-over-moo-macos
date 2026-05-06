local requestChannelName, responseChannelName, cancelChannelName = ...

package.path = (package.path or "") .. ";./?.lua;./?/init.lua"

local requestChannel = love.thread.getChannel(requestChannelName)
local responseChannel = love.thread.getChannel(responseChannelName)
local cancelChannel = love.thread.getChannel(cancelChannelName)

local function push(message)
    message = message or {}
    responseChannel:push(message)
end

local function isCancelled()
    return cancelChannel:peek() ~= nil
end

local function reasonCodesFromQuality(result)
    local codes = {}
    local function collect(list)
        for _, entry in ipairs(list or {}) do
            local code = type(entry) == "table" and entry.code or entry
            if code ~= nil then
                codes[#codes + 1] = tostring(code)
            end
        end
    end
    collect(result and result.reasons)
    collect(result and result.unknowns)
    if #codes == 0 then
        return "no_quality_reason"
    end
    return table.concat(codes, ", ")
end

local function summarizeRejectedGeneration(dossier, quality)
    local qualityReasons = reasonCodesFromQuality(quality)
    if qualityReasons ~= "no_quality_reason" then
        return qualityReasons
    end

    local codes = {}
    for _, reason in ipairs(dossier and dossier.rejectionReasons or {}) do
        local code = type(reason) == "table" and reason.code or reason
        if code ~= nil then
            codes[#codes + 1] = tostring(code)
        end
    end
    if #codes > 0 then
        return table.concat(codes, ", ")
    end
    return "candidate_not_approved"
end

local function hasActiveRedUnit(dossier)
    local units = dossier and dossier.scenarioState and dossier.scenarioState.units or {}
    for _, unit in ipairs(units) do
        local hp = tonumber(unit.currentHp) or tonumber(unit.hp) or 0
        if hp > 0 and tonumber(unit.player) == 2 and tostring(unit.name or "") ~= "Commandant" then
            return true
        end
    end
    return false
end

local function stableString(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function liveBlueUnitIds(dossier)
    local ids = {}
    local units = dossier and dossier.scenarioState and dossier.scenarioState.units or {}
    for index, unit in ipairs(units) do
        local hp = tonumber(unit.currentHp) or tonumber(unit.hp) or 0
        if hp > 0 and tonumber(unit.player) == 1 then
            local id = stableString(unit.scenarioUnitId or unit.id or index)
            if id ~= "" then
                ids[id] = true
            end
        end
    end
    return ids
end

local function blueCoordinationContract(actions, blueActorIds, finisherId)
    local supportActions = 0
    local finisherActions = 0
    local supportActors = {}
    local firstBlueAction = nil
    local supportAttackBeforePayoff = false
    local finisherPayoff = false
    finisherId = stableString(finisherId or "blue_finisher")

    for _, action in ipairs(actions or {}) do
        if type(action) == "table" then
            local actor = stableString(action.actorId)
            local isBlueActor = blueActorIds[actor] == true
            if isBlueActor and actor ~= finisherId then
                supportActions = supportActions + 1
                supportActors[actor] = true
                firstBlueAction = firstBlueAction or action
                if action.type == "attack" and not finisherPayoff then
                    supportAttackBeforePayoff = true
                end
            elseif isBlueActor and actor == finisherId then
                finisherActions = finisherActions + 1
                firstBlueAction = firstBlueAction or action
                if action.type == "attack" and action.targetId == "red_commandant" then
                    finisherPayoff = true
                end
            end
        end
    end

    local supportActorCount = 0
    for _ in pairs(supportActors) do
        supportActorCount = supportActorCount + 1
    end

    return supportActions >= 2
        and finisherActions >= 2
        and type(firstBlueAction) == "table"
        and blueActorIds[stableString(firstBlueAction.actorId)] == true
        and stableString(firstBlueAction.actorId) ~= finisherId
        and firstBlueAction.type == "move"
        and supportAttackBeforePayoff == true
        and supportActorCount >= 1
        and finisherPayoff == true
end

local function hasBlueCoordination(dossier)
    local blueActorIds = liveBlueUnitIds(dossier)
    if blueCoordinationContract(dossier and dossier.solution and dossier.solution.actions or {}, blueActorIds, "blue_finisher") then
        return true
    end
    return blueCoordinationContract(dossier and dossier.solverProof and dossier.solverProof.winningLine or {}, blueActorIds, "blue_finisher")
end

local request = requestChannel:demand()
if type(request) ~= "table" then
    push({ status = "error", reason = "missing_request" })
    return
end

local okGenerator, retroGenerator = pcall(require, "scenario_tooling.retro_generator")
local okQuality, qualityEvaluator = pcall(require, "scenario_tooling.quality_evaluator")
if not okGenerator or type(retroGenerator) ~= "table" or type(retroGenerator.generate) ~= "function"
    or not okQuality or type(qualityEvaluator) ~= "table" or type(qualityEvaluator.evaluate) ~= "function" then
    push({ token = request.token, status = "error", reason = "generator_unavailable" })
    return
end

local profiles = request.profiles or {}
local profileCount = #profiles
if profileCount <= 0 then
    push({ token = request.token, status = "error", reason = "empty_profile_list" })
    return
end

local maxAttempts = math.max(1, math.floor(tonumber(request.maxAttempts) or 1))
local seedBase = math.max(1, math.floor(tonumber(request.seedBase) or 1))
local profileStartIndex = math.max(1, math.floor(tonumber(request.profileStartIndex) or 1))
local solverMaxNodes = math.max(1, math.floor(tonumber(request.solverMaxNodes) or 9000))

for attempt = 1, maxAttempts do
    if isCancelled() then
        push({ token = request.token, status = "cancelled", attempt = attempt - 1 })
        return
    end

    local profileIndex = ((profileStartIndex + attempt - 2) % profileCount) + 1
    local profile = profiles[profileIndex]
    local archetype = profile and profile.archetype or nil
    local label = profile and (profile.label or profile.archetype) or "unknown"
    local allowEditorPlaytest = profile and profile.allowEditorPlaytest == true
    local seed = (seedBase + (attempt * 104729) + (profileIndex * 4099)) % 4294967296

    push({
        token = request.token,
        status = "attempt",
        attempt = attempt,
        maxAttempts = maxAttempts,
        seed = seed,
        archetype = archetype,
        label = label
    })

    local dossier = retroGenerator.generate({
        seed = seed,
        turnLimit = 3,
        archetype = archetype,
        solverMaxNodes = solverMaxNodes,
        maxAttempts = 1
    })
    local quality = qualityEvaluator.evaluate(dossier)
    local isCertified = type(dossier) == "table" and dossier.pipelineState == "certified"
    local isQualityApproved = type(quality) == "table" and quality.status == "approved"
    local canLoadForEditor = isCertified and (isQualityApproved or allowEditorPlaytest)

    if canLoadForEditor then
        if not hasActiveRedUnit(dossier) then
            push({
                token = request.token,
                status = "rejected",
                attempt = attempt,
                maxAttempts = maxAttempts,
                seed = seed,
                archetype = archetype,
                label = label,
                reason = "generated_state_has_no_active_red_unit"
            })
        elseif not hasBlueCoordination(dossier) then
            push({
                token = request.token,
                status = "rejected",
                attempt = attempt,
                maxAttempts = maxAttempts,
                seed = seed,
                archetype = archetype,
                label = label,
                reason = "generated_state_lacks_blue_coordination"
            })
        else
            push({
                token = request.token,
                status = "certified",
                attempt = attempt,
                maxAttempts = maxAttempts,
                seed = seed,
                archetype = archetype,
                label = label,
                playtestOnly = allowEditorPlaytest and not isQualityApproved,
                dossier = dossier,
                quality = quality
            })
            return
        end
    else
        push({
            token = request.token,
            status = "rejected",
            attempt = attempt,
            maxAttempts = maxAttempts,
            seed = seed,
            archetype = archetype,
            label = label,
            reason = summarizeRejectedGeneration(dossier, quality)
        })
    end
end

push({
    token = request.token,
    status = "failed",
    attempt = maxAttempts,
    maxAttempts = maxAttempts,
    reason = "generated_candidates_rejected"
})
