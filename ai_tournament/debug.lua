local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function formatPos(pos)
    if type(pos) ~= "table" then
        return "?,?"
    end
    return string.format("%d,%d", num(pos.row, 0), num(pos.col, 0))
end

local function formatActionList(actions)
    local list = {}
    for _, action in ipairs(actions or {}) do
        list[#list + 1] = M.formatAction(action)
    end
    return list
end

function M.formatAction(action)
    if not action then
        return "invalid"
    end

    local actionType = action.type
    if actionType == "attack" then
        return string.format("attack %s -> %s", formatPos(action.unit), formatPos(action.target))
    end
    if actionType == "move" then
        return string.format("move %s -> %s", formatPos(action.unit), formatPos(action.target))
    end
    if actionType == "repair" then
        return string.format("repair %s -> %s", formatPos(action.unit), formatPos(action.target))
    end
    if actionType == "supply_deploy" then
        return string.format("deploy %s -> %s", tostring(action.unitName or action.unitType or "?"), formatPos(action.target))
    end
    if actionType == "skip" then
        return "skip"
    end
    return tostring(actionType or "unknown")
end

function M.buildLogPayload(meta, sequence, sanitizeSummary)
    local selected = meta and meta.selected or {}
    local selectedCandidate = selected and selected.candidate or {}
    local stats = meta and meta.stats or {}
    local sanitize = nil
    if type(sanitizeSummary) == "table" then
        sanitize = {
            replacements = sanitizeSummary.replacements,
            reasonCounts = sanitizeSummary.reasonCounts
        }
    end

    return {
        reason = meta and meta.reason or "unknown",
        contract = meta and meta.contract or nil,
        elapsedMs = meta and meta.elapsedMs or nil,
        actions = formatActionList(sequence or (selectedCandidate and selectedCandidate.actions)),
        selected = selectedCandidate and selectedCandidate.signature,
        hardSelectionLocked = stats.hardSelectionLocked == true,
        hardSelectionReason = stats.hardSelectionReason,
        hardSelectionSignature = stats.hardSelectionSignature,
        hardSelectionPrefixCompleted = stats.hardSelectionPrefixCompleted == true,
        hardSelectionPrefixSignature = stats.hardSelectionPrefixSignature,
        hardSelectionCompletedSignature = stats.hardSelectionCompletedSignature,
        hardSelectionRejected = stats.hardSelectionRejected == true,
        hardSelectionRejectReason = stats.hardSelectionRejectReason,
        hardSelectionRejectStage = stats.hardSelectionRejectStage,
        hardSelectionRejectSignature = stats.hardSelectionRejectSignature,
        hardSelectionRejectSanitizerReplacements = stats.hardSelectionRejectSanitizerReplacements,
        hardSelectionRejectSanitizerReasonCounts = stats.hardSelectionRejectSanitizerReasonCounts,
        hardSelectionFallbackPath = stats.hardSelectionFallbackPath,
        coreExit = stats.coreExit,
        fallbackSource = stats.fallbackSource,
        bestSoFarAvailable = stats.bestSoFarAvailable == true,
        bestSoFarSource = stats.bestSoFarSource,
        bestSoFarSignature = stats.bestSoFarSignature,
        evaluatedCandidates = stats.evaluatedCandidates,
        sanitize = sanitize
    }
end

function M.logDecision(ai, meta, sequence, sanitizeSummary)
    if not ai or not ai.logDecision then
        return
    end

    local cfg = ai.getTournamentConfig and ai:getTournamentConfig() or {}
    if cfg.LOG_SUMMARY ~= true then
        return
    end

    local stats = meta and meta.stats or {}
    local message = string.format(
        "TournamentPrime contract=%s reason=%s phase=%s/%s@%s:%s early=%s/%s lane=%s eForm=%.1f tactic=%s hardLock=%s/%s hardFill=%s hardReject=%s/%s hardRejectStage=%s hardFallback=%s hardRejectSeq=%s coreExit=%s bestSoFar=%s/%s fallbackSource=%s fallback=%s selectedAttack=%s seq=%s elapsed=%.1fms timeout=%s",
        tostring(meta and meta.contract or "none"),
        tostring(meta and meta.reason or "unknown"),
        tostring(stats.phase or "unknown"),
        tostring(stats.phaseReason or "none"),
        tostring(stats.phaseEarlyReference or "base"),
        tostring(stats.phaseEarlyMax or "na"),
        tostring(stats.earlyRole or "none"),
        tostring(stats.earlyIntent or "none"),
        tostring(stats.earlyFocalLane or "none"),
        num(stats.earlyFormationScore, 0),
        tostring(stats.tacticalOverrideReason or "none"),
        tostring(stats.hardSelectionLocked == true),
        tostring(stats.hardSelectionReason or "none"),
        tostring(stats.hardSelectionPrefixCompleted == true),
        tostring(stats.hardSelectionRejected == true),
        tostring(stats.hardSelectionRejectReason or "none"),
        tostring(stats.hardSelectionRejectStage or "none"),
        tostring(stats.hardSelectionFallbackPath or "none"),
        tostring(stats.hardSelectionRejectSignature or "none"),
        tostring(stats.coreExit or "not_reported"),
        tostring(stats.bestSoFarAvailable == true),
        tostring(stats.bestSoFarSource or "none"),
        tostring(stats.fallbackSource or "none"),
        tostring(meta and meta.fallbackReason or "none"),
        tostring(stats.selectedHasFactionAttack == true),
        tostring((meta and meta.selected and meta.selected.candidate and meta.selected.candidate.signature) or ""),
        num(meta and meta.elapsedMs, 0),
        tostring(stats.timeout == true)
    )

    local payload = M.buildLogPayload(meta, sequence, sanitizeSummary)
    ai:logDecision("TournamentAI", message, payload)
end

return M
