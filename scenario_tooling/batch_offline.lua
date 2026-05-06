local retroGenerator = require("scenario_tooling.retro_generator")
local qualityEvaluator = require("scenario_tooling.quality_evaluator")

local M = {
    VERSION = "scenario_batch_offline.v1.step10",
    BATCH_ID = "step10_batch_offline_v1",
    BATCH_HASH = "scenario_batch_offline_pending_hash"
}

local UINT32_MOD = 4294967296
local SEED_STEP = 362437
local DEFAULT_COUNT = 10
local DEFAULT_TURN_LIMIT = 3

local function stableString(v)
    if v == nil then
        return ""
    end
    if type(v) == "number" then
        return string.format("%.12g", v)
    end
    return tostring(v)
end

local function hashText(text)
    local hash = 5381
    local i
    for i = 1, #text do
        hash = ((hash * 33) + string.byte(text, i)) % UINT32_MOD
    end
    return string.format("%08x", hash)
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    local k, v
    for k, v in pairs(value) do
        out[deepCopy(k, seen)] = deepCopy(v, seen)
    end
    return out
end

local function shallowCopy(tbl)
    local out = {}
    if type(tbl) ~= "table" then
        return out
    end
    local k, v
    for k, v in pairs(tbl) do
        out[k] = v
    end
    return out
end

local function normalizeSeed(seed)
    if type(seed) == "number" then
        local n = math.floor(seed)
        if n < 0 then
            n = -n
        end
        return n % UINT32_MOD
    end
    if type(seed) == "string" and seed ~= "" then
        return tonumber(hashText(seed), 16)
    end
    return 1
end

local function normalizeCount(value)
    local n = tonumber(value) or DEFAULT_COUNT
    n = math.floor(n)
    if n < 1 then
        n = 1
    end
    return n
end

local function normalizeTurnLimit(value)
    local n = tonumber(value) or DEFAULT_TURN_LIMIT
    n = math.floor(n)
    if n < 1 then
        n = 1
    end
    return n
end

local function deriveSeed(baseSeed, index)
    local idx = tonumber(index) or 1
    if idx < 1 then
        idx = 1
    end
    idx = math.floor(idx)
    return (baseSeed + ((idx - 1) * SEED_STEP)) % UINT32_MOD
end

local function normalizeOpts(opts, checkpoint)
    opts = type(opts) == "table" and opts or {}
    local cp = type(checkpoint) == "table" and checkpoint or {}
    local out = shallowCopy(opts)
    out.seed = normalizeSeed(opts.seed ~= nil and opts.seed or cp.seed)
    out.count = normalizeCount(opts.count ~= nil and opts.count or cp.requestedCount or cp.count)
    out.turnLimit = normalizeTurnLimit(opts.turnLimit ~= nil and opts.turnLimit or cp.turnLimit)
    if type(opts.runDir) ~= "string" or opts.runDir == "" then
        out.runDir = nil
    end
    return out
end

local function gatherCodes(reasons)
    local out = {}
    local i
    for i = 1, #(type(reasons) == "table" and reasons or {}) do
        local reason = reasons[i]
        local code = stableString(type(reason) == "table" and reason.code or reason)
        if code ~= "" then
            out[#out + 1] = code
        end
    end
    table.sort(out)
    return out
end

local function buildRejectRecord(index, seed, dossier, evaluation)
    local evalStatus = stableString(type(evaluation) == "table" and evaluation.status or "")
    if evalStatus == "" then
        evalStatus = "unknown"
    end
    local reasons = gatherCodes(type(evaluation) == "table" and evaluation.reasons or nil)
    local unknowns = gatherCodes(type(evaluation) == "table" and evaluation.unknowns or nil)
    if type(dossier) == "table" then
        local generatorReasons = gatherCodes(dossier.rejectionReasons)
        local seen = {}
        local i
        for i = 1, #reasons do
            seen[reasons[i]] = true
        end
        for i = 1, #generatorReasons do
            if not seen[generatorReasons[i]] then
                reasons[#reasons + 1] = generatorReasons[i]
                seen[generatorReasons[i]] = true
            end
        end
        table.sort(reasons)
    end
    return {
        index = index,
        seed = seed,
        status = evalStatus,
        pipelineState = stableString(type(dossier) == "table" and dossier.pipelineState or "missing"),
        reasonCodes = reasons,
        unknownCodes = unknowns
    }
end

local function makeEntryFromCheckpoint(index, checkpointEntry, expectedSeed, turnLimit)
    if type(checkpointEntry) ~= "table" then
        return nil
    end
    if checkpointEntry.completed ~= true then
        return nil
    end
    if tonumber(checkpointEntry.seed) ~= tonumber(expectedSeed) then
        return nil
    end
    if tonumber(checkpointEntry.turnLimit) ~= tonumber(turnLimit) then
        return nil
    end
    local entry = deepCopy(checkpointEntry)
    entry.index = index
    return entry
end

local function entryIsApproved(entry)
    if type(entry) ~= "table" then
        return false
    end
    if entry.approved ~= true then
        return false
    end
    local dossier = entry.dossier
    local evaluation = entry.evaluation
    if type(dossier) ~= "table" or dossier.pipelineState ~= "certified" then
        return false
    end
    if type(evaluation) ~= "table" or evaluation.status ~= "approved" then
        return false
    end
    return true
end

local function tableKeySort(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then
        return ta < tb
    end
    if ta == "number" then
        return a < b
    end
    return stableString(a) < stableString(b)
end

local function encodeLuaString(str)
    str = tostring(str or "")
    str = str:gsub("\\", "\\\\")
    str = str:gsub("\n", "\\n")
    str = str:gsub("\r", "\\r")
    str = str:gsub("\t", "\\t")
    str = str:gsub("\"", "\\\"")
    return "\"" .. str .. "\""
end

local function encodeLuaValue(value, indent, seen)
    indent = indent or 0
    seen = seen or {}
    local t = type(value)
    if t == "nil" then
        return "nil"
    end
    if t == "boolean" then
        return value and "true" or "false"
    end
    if t == "number" then
        return stableString(value)
    end
    if t == "string" then
        return encodeLuaString(value)
    end
    if t ~= "table" then
        return encodeLuaString(stableString(value))
    end
    if seen[value] then
        return "\"<cycle>\""
    end
    seen[value] = true

    local pad = string.rep(" ", indent)
    local childPad = string.rep(" ", indent + 2)
    local lines = { "{" }
    local maxArray = #value
    local i
    for i = 1, maxArray do
        lines[#lines + 1] = childPad .. encodeLuaValue(value[i], indent + 2, seen) .. ","
    end
    local keys = {}
    local k
    for k in pairs(value) do
        if not (type(k) == "number" and k >= 1 and k <= maxArray and math.floor(k) == k) then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, tableKeySort)
    for i = 1, #keys do
        k = keys[i]
        local keyText
        if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then
            keyText = k
        else
            keyText = "[" .. encodeLuaValue(k, indent + 2, seen) .. "]"
        end
        lines[#lines + 1] = childPad .. keyText .. " = " .. encodeLuaValue(value[k], indent + 2, seen) .. ","
    end
    lines[#lines + 1] = pad .. "}"
    seen[value] = nil
    return table.concat(lines, "\n")
end

local function shellQuote(path)
    local text = tostring(path or "")
    text = text:gsub("'", "'\\''")
    return "'" .. text .. "'"
end

local function commandSucceeded(ok, how, code)
    if ok == true then
        return true
    end
    if type(ok) == "number" then
        return ok == 0
    end
    if how == "exit" and code == 0 then
        return true
    end
    return false
end

local function ensureDir(path)
    if type(path) ~= "string" or path == "" then
        return false, "invalid_path"
    end
    local ok, how, code = os.execute("mkdir -p " .. shellQuote(path))
    if not commandSucceeded(ok, how, code) then
        return false, "mkdir_failed"
    end
    return true
end

local function joinPath(a, b)
    if type(a) ~= "string" or a == "" then
        return b
    end
    if type(b) ~= "string" or b == "" then
        return a
    end
    if string.sub(a, -1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function writeTextFile(path, content)
    local fh, err = io.open(path, "w")
    if not fh then
        return false, err
    end
    fh:write(content or "")
    fh:close()
    return true
end

local function formatCodeList(codes)
    if type(codes) ~= "table" or #codes == 0 then
        return "-"
    end
    return table.concat(codes, ",")
end

local function writeRunArtifacts(report, runDir)
    local approvedDir = joinPath(runDir, "approved")
    local rejectsDir = joinPath(runDir, "rejects")
    local okA = ensureDir(approvedDir)
    local okR = ensureDir(rejectsDir)
    if not okA or not okR then
        return false, "directory_setup_failed"
    end

    local approvedManifest = {}
    local rejectManifest = {}
    local i
    for i = 1, #report.approved do
        local item = report.approved[i]
        local fileName = string.format("approved_%06d_seed_%u.lua", item.index, item.seed)
        local filePath = joinPath(approvedDir, fileName)
        local contentLines = {
            "-- scenario_batch_offline_approved_v1",
            "status=approved",
            "pipelineState=certified",
            "index=" .. tostring(item.index),
            "seed=" .. tostring(item.seed),
            "",
            "return " .. encodeLuaValue(item.dossier)
        }
        local okWrite, err = writeTextFile(filePath, table.concat(contentLines, "\n"))
        if not okWrite then
            return false, "approved_write_failed:" .. stableString(err)
        end
        approvedManifest[#approvedManifest + 1] = table.concat({
            tostring(item.index),
            tostring(item.seed),
            "approved",
            "certified",
            fileName
        }, "\t")
    end

    for i = 1, #report.rejectLog do
        local item = report.rejectLog[i]
        local fileName = string.format("reject_%06d_seed_%u.txt", item.index, item.seed)
        local filePath = joinPath(rejectsDir, fileName)
        local lines = {
            "index=" .. tostring(item.index),
            "seed=" .. tostring(item.seed),
            "status=" .. stableString(item.status),
            "pipelineState=" .. stableString(item.pipelineState),
            "reasonCodes=" .. formatCodeList(item.reasonCodes),
            "unknownCodes=" .. formatCodeList(item.unknownCodes)
        }
        local okWrite, err = writeTextFile(filePath, table.concat(lines, "\n") .. "\n")
        if not okWrite then
            return false, "reject_write_failed:" .. stableString(err)
        end
        rejectManifest[#rejectManifest + 1] = table.concat({
            tostring(item.index),
            tostring(item.seed),
            stableString(item.status),
            stableString(item.pipelineState),
            fileName
        }, "\t")
    end

    local approvedManifestPath = joinPath(approvedDir, "_manifest.tsv")
    local rejectManifestPath = joinPath(rejectsDir, "_manifest.tsv")
    local okM1 = writeTextFile(approvedManifestPath, table.concat(approvedManifest, "\n"))
    local okM2 = writeTextFile(rejectManifestPath, table.concat(rejectManifest, "\n"))
    if not okM1 or not okM2 then
        return false, "manifest_write_failed"
    end
    return true
end

local function listFlatFiles(path)
    if type(path) ~= "string" or path == "" then
        return nil, "invalid_path"
    end
    local handle = io.popen("find " .. shellQuote(path) .. " -maxdepth 1 -type f -print 2>/dev/null")
    if not handle then
        return nil, "find_failed"
    end
    local files = {}
    for line in handle:lines() do
        files[#files + 1] = line
    end
    handle:close()
    table.sort(files)
    return files
end

function M.isScenarioOnly()
    return true
end

function M.cleanApprovedFolder(reportOrRunDir)
    if type(reportOrRunDir) == "table" then
        local report = reportOrRunDir
        local issues = {}
        local checked = 0
        local i
        for i = 1, #(report.approved or {}) do
            checked = checked + 1
            local entry = report.approved[i]
            local dossier = entry and entry.dossier
            local evaluation = entry and entry.evaluation
            if type(dossier) ~= "table" or dossier.pipelineState ~= "certified" then
                issues[#issues + 1] = "approved_entry_not_certified:index=" .. tostring(entry and entry.index or i)
            end
            if type(evaluation) ~= "table" or evaluation.status ~= "approved" then
                issues[#issues + 1] = "approved_entry_bad_status:index=" .. tostring(entry and entry.index or i)
            end
        end
        return {
            clean = #issues == 0,
            checked = checked,
            issues = issues
        }
    end

    if type(reportOrRunDir) == "string" and reportOrRunDir ~= "" then
        local approvedDir = joinPath(reportOrRunDir, "approved")
        local files, err = listFlatFiles(approvedDir)
        if not files then
            return {
                clean = false,
                checked = 0,
                issues = { "unable_to_list_approved_folder:" .. stableString(err) }
            }
        end
        local checked = 0
        local issues = {}
        local i
        for i = 1, #files do
            local path = files[i]
            if not string.match(path, "_manifest%.tsv$") then
                checked = checked + 1
                local fh = io.open(path, "r")
                if not fh then
                    issues[#issues + 1] = "cannot_read:" .. stableString(path)
                else
                    local content = fh:read("*a") or ""
                    fh:close()
                    if content:find("status=approved", 1, true) == nil then
                        issues[#issues + 1] = "missing_status_approved:" .. stableString(path)
                    end
                    if content:find("pipelineState=certified", 1, true) == nil then
                        issues[#issues + 1] = "missing_pipeline_certified:" .. stableString(path)
                    end
                end
            end
        end
        return {
            clean = #issues == 0,
            checked = checked,
            issues = issues
        }
    end

    return {
        clean = false,
        checked = 0,
        issues = { "invalid_clean_input" }
    }
end

function M.formatRejectLog(report)
    if type(report) ~= "table" or type(report.rejectLog) ~= "table" or #report.rejectLog == 0 then
        return "No rejected or unknown dossiers."
    end
    local lines = {}
    local i
    for i = 1, #report.rejectLog do
        local item = report.rejectLog[i]
        lines[#lines + 1] = table.concat({
            "#" .. tostring(item.index),
            "seed=" .. tostring(item.seed),
            "status=" .. stableString(item.status),
            "pipelineState=" .. stableString(item.pipelineState),
            "reasonCodes=" .. formatCodeList(item.reasonCodes),
            "unknownCodes=" .. formatCodeList(item.unknownCodes)
        }, " | ")
    end
    return table.concat(lines, "\n")
end

local function makeEmptyReport(opts)
    local startEpoch = os.time()
    return {
        status = "incomplete",
        requestedCount = opts.count,
        completedCount = 0,
        approvedCount = 0,
        rejectedCount = 0,
        unknownCount = 0,
        notGeneratedCount = 0,
        approved = {},
        rejectLog = {},
        timing = {
            startedAtEpoch = startEpoch,
            finishedAtEpoch = nil,
            totalSeconds = 0,
            generationSeconds = 0,
            evaluationSeconds = 0,
            perAttemptSeconds = {}
        },
        checkpoint = {},
        approvedFolderClean = false,
        diagnostics = {
            batchVersion = M.VERSION,
            batchId = M.BATCH_ID,
            batchHash = M.BATCH_HASH,
            generatorVersion = retroGenerator.VERSION,
            evaluatorVersion = qualityEvaluator.VERSION,
            seed = opts.seed,
            count = opts.count,
            turnLimit = opts.turnLimit,
            seedStep = SEED_STEP,
            modulesScenarioOnly = (
                retroGenerator.isScenarioOnly and retroGenerator.isScenarioOnly() == true
                and qualityEvaluator.isScenarioOnly and qualityEvaluator.isScenarioOnly() == true
            ),
            reusedCheckpointEntries = 0,
            generatedEntries = 0,
            runDir = opts.runDir
        }
    }
end

local function finalizeCounts(report, entries, count)
    local i
    for i = 1, count do
        local entry = entries[i]
        if type(entry) == "table" and entry.completed == true then
            report.completedCount = report.completedCount + 1
            if entryIsApproved(entry) then
                report.approvedCount = report.approvedCount + 1
                report.approved[#report.approved + 1] = {
                    index = entry.index,
                    seed = entry.seed,
                    dossier = deepCopy(entry.dossier),
                    evaluation = deepCopy(entry.evaluation),
                    quality = deepCopy(entry.evaluation)
                }
            else
                local pipelineState = stableString(entry.pipelineState)
                local evalStatus = stableString(entry.evaluationStatus)
                if pipelineState == "not_generated" then
                    report.notGeneratedCount = report.notGeneratedCount + 1
                elseif evalStatus == "reject" then
                    report.rejectedCount = report.rejectedCount + 1
                elseif evalStatus == "unknown" then
                    report.unknownCount = report.unknownCount + 1
                else
                    report.unknownCount = report.unknownCount + 1
                end
                report.rejectLog[#report.rejectLog + 1] = deepCopy(entry.rejectRecord or {
                    index = entry.index,
                    seed = entry.seed,
                    status = evalStatus ~= "" and evalStatus or "unknown",
                    pipelineState = pipelineState ~= "" and pipelineState or "missing",
                    reasonCodes = {},
                    unknownCodes = {}
                })
            end
        end
    end
    table.sort(report.approved, function(a, b)
        return a.index < b.index
    end)
    table.sort(report.rejectLog, function(a, b)
        return a.index < b.index
    end)
end

local function normalizeCheckpoint(checkpoint)
    if type(checkpoint) ~= "table" then
        return {
            schema = "ScenarioBatchCheckpoint",
            entries = {}
        }
    end
    local out = {
        schema = checkpoint.schema or "ScenarioBatchCheckpoint",
        version = checkpoint.version or M.VERSION,
        batchId = checkpoint.batchId or M.BATCH_ID,
        batchHash = checkpoint.batchHash or M.BATCH_HASH,
        seed = checkpoint.seed,
        requestedCount = checkpoint.requestedCount or checkpoint.count,
        turnLimit = checkpoint.turnLimit,
        entries = {}
    }
    local i
    for i = 1, #(checkpoint.entries or {}) do
        out.entries[i] = deepCopy(checkpoint.entries[i])
    end
    return out
end

local function executeBatch(checkpoint, opts)
    local normalizedCheckpoint = normalizeCheckpoint(checkpoint)
    local config = normalizeOpts(opts, normalizedCheckpoint)
    local report = makeEmptyReport(config)
    local entries = {}
    local totalStart = os.clock()

    local i
    for i = 1, config.count do
        local attemptSeed = deriveSeed(config.seed, i)
        local reused = makeEntryFromCheckpoint(i, normalizedCheckpoint.entries[i], attemptSeed, config.turnLimit)
        if reused then
            entries[i] = reused
            report.diagnostics.reusedCheckpointEntries = report.diagnostics.reusedCheckpointEntries + 1
        else
            local attemptStart = os.clock()
            local genStart = os.clock()
            local genOpts = shallowCopy(config)
            genOpts.seed = attemptSeed
            genOpts.count = nil
            local dossier, generatorDiagnostics = retroGenerator.generate(genOpts)
            local genElapsed = os.clock() - genStart

            local evalStart = os.clock()
            local evaluation = qualityEvaluator.evaluate(dossier, {
                seed = attemptSeed,
                turnLimit = config.turnLimit
            })
            local evalElapsed = os.clock() - evalStart
            local totalElapsed = os.clock() - attemptStart

            local evalStatus = stableString(type(evaluation) == "table" and evaluation.status or "")
            if evalStatus == "" then
                evalStatus = "unknown"
            end
            local pipelineState = stableString(type(dossier) == "table" and dossier.pipelineState or "missing")
            local approved = evalStatus == "approved" and pipelineState == "certified"

            entries[i] = {
                index = i,
                seed = attemptSeed,
                turnLimit = config.turnLimit,
                completed = true,
                pipelineState = pipelineState,
                evaluationStatus = evalStatus,
                approved = approved,
                dossier = approved and deepCopy(dossier) or nil,
                evaluation = approved and deepCopy(evaluation) or nil,
                rejectRecord = approved and nil or buildRejectRecord(i, attemptSeed, dossier, evaluation),
                timing = {
                    generationSeconds = genElapsed,
                    evaluationSeconds = evalElapsed,
                    totalSeconds = totalElapsed
                },
                generatorDiagnostics = deepCopy(generatorDiagnostics)
            }

            report.diagnostics.generatedEntries = report.diagnostics.generatedEntries + 1
            report.timing.generationSeconds = report.timing.generationSeconds + genElapsed
            report.timing.evaluationSeconds = report.timing.evaluationSeconds + evalElapsed
            report.timing.perAttemptSeconds[#report.timing.perAttemptSeconds + 1] = totalElapsed
        end
    end

    finalizeCounts(report, entries, config.count)

    local nextIndex = config.count + 1
    for i = 1, config.count do
        if type(entries[i]) ~= "table" or entries[i].completed ~= true then
            nextIndex = i
            break
        end
    end

    local checkpointOut = {
        schema = "ScenarioBatchCheckpoint",
        version = M.VERSION,
        batchId = M.BATCH_ID,
        batchHash = M.BATCH_HASH,
        seed = config.seed,
        requestedCount = config.count,
        turnLimit = config.turnLimit,
        nextIndex = nextIndex,
        entries = entries
    }
    report.checkpoint = checkpointOut

    if report.completedCount < report.requestedCount then
        report.status = "incomplete"
        report.outcome = "incomplete"
    else
        report.status = "completed"
        if report.approvedCount == report.requestedCount then
            report.outcome = "all_approved"
        elseif report.notGeneratedCount > 0 then
            report.outcome = "with_not_generated"
        elseif report.rejectedCount > 0 or report.unknownCount > 0 then
            report.outcome = "with_rejections"
        else
            report.outcome = "completed"
        end
    end

    local memClean = M.cleanApprovedFolder(report)
    report.approvedFolderClean = memClean.clean
    report.diagnostics.approvedFolderCheck = {
        inMemory = memClean
    }

    if type(config.runDir) == "string" and config.runDir ~= "" then
        local writeOk, writeErr = writeRunArtifacts(report, config.runDir)
        report.diagnostics.artifactWrite = {
            ok = writeOk == true,
            error = writeOk and nil or writeErr,
            runDir = config.runDir
        }
        local diskClean = M.cleanApprovedFolder(config.runDir)
        report.diagnostics.approvedFolderCheck.onDisk = diskClean
        report.approvedFolderClean = report.approvedFolderClean and diskClean.clean and writeOk == true
    end

    report.timing.totalSeconds = os.clock() - totalStart
    report.timing.finishedAtEpoch = os.time()
    return report
end

function M.run(opts)
    return executeBatch(nil, opts or {})
end

function M.resume(checkpoint, opts)
    return executeBatch(checkpoint, opts or {})
end

M.BATCH_HASH = hashText(table.concat({
    M.VERSION,
    M.BATCH_ID,
    retroGenerator.VERSION or "",
    retroGenerator.GENERATOR_HASH or "",
    qualityEvaluator.VERSION or "",
    qualityEvaluator.EVALUATOR_HASH or ""
}, "|"))

return M
