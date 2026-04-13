local logger = require("logger")
local os = require("os")

local perfMetrics = {}

local RING_SIZE = 240
local SUMMARY_INTERVAL_SECONDS = 5
local OVERLAY_REFRESH_INTERVAL = 0.25
local DEFAULT_SECTION_NAMES = {
    "update",
    "draw",
    "ai_turn",
    "grid_draw",
    "ui_draw"
}

local frameBuffer = {}
local sectionBuffers = {}
local sectionTotals = {}
local sectionStarts = {}
local sectionOrder = {}

local frameWriteIndex = 1
local frameCount = 0
local frameStartTime = nil
local frameActive = false

local summaryTimer = 0
local overlaySnapshot = nil
local overlaySnapshotAt = 0
local captureFrames = {}
local sessionName = "gameplay"
local sessionStartedAt = nil
local sessionStartedDate = nil

local function toNumber(value, fallback)
    local numeric = tonumber(value)
    if numeric == nil then
        return fallback
    end
    return numeric
end

local function nowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

local function getPerfConfig()
    local settings = SETTINGS or {}
    return settings.PERF or {}
end

local function profilingEnabled()
    local config = getPerfConfig()
    return config.ENABLE_PROFILING == true
        or config.OVERLAY_ENABLED == true
        or config.CAPTURE_ENABLED == true
end

local function pushSample(buffer, value)
    buffer[frameWriteIndex] = value
end

local function sampleCount()
    return frameCount
end

local function collectSamples(buffer)
    local count = sampleCount()
    if count <= 0 then
        return {}
    end

    local values = {}
    if count < RING_SIZE then
        for i = 1, count do
            values[i] = buffer[i]
        end
        return values
    end

    local idx = frameWriteIndex
    for i = 1, RING_SIZE do
        values[i] = buffer[idx]
        idx = idx + 1
        if idx > RING_SIZE then
            idx = 1
        end
    end
    return values
end

local function sortedCopy(values)
    local copy = {}
    for i = 1, #values do
        copy[i] = values[i]
    end
    table.sort(copy)
    return copy
end

local function percentile(values, p)
    if #values == 0 then
        return 0
    end
    local sorted = sortedCopy(values)
    local index = math.max(1, math.min(#sorted, math.floor((#sorted - 1) * p + 1.5)))
    return sorted[index]
end

local function average(values)
    if #values == 0 then
        return 0
    end
    local total = 0
    for i = 1, #values do
        total = total + values[i]
    end
    return total / #values
end

local function getOrCreateSectionBuffer(name)
    if not sectionBuffers[name] then
        sectionBuffers[name] = {}
        sectionTotals[name] = 0
        sectionOrder[#sectionOrder + 1] = name
    end
    return sectionBuffers[name]
end

local function ensureDefaultSections()
    for _, name in ipairs(DEFAULT_SECTION_NAMES) do
        getOrCreateSectionBuffer(name)
    end
end

ensureDefaultSections()

local function resetBuffers()
    frameBuffer = {}
    sectionBuffers = {}
    sectionTotals = {}
    sectionStarts = {}
    sectionOrder = {}
    frameWriteIndex = 1
    frameCount = 0
    summaryTimer = 0
    overlaySnapshot = nil
    overlaySnapshotAt = 0
    captureFrames = {}
    ensureDefaultSections()
end

function perfMetrics.startSession(name)
    resetBuffers()
    sessionName = tostring(name or "gameplay")
    sessionStartedAt = nowSeconds()
    sessionStartedDate = os.date("%Y-%m-%d %H:%M:%S")
end

local function ensureSessionStarted()
    if not sessionStartedAt then
        perfMetrics.startSession("gameplay")
    end
end

function perfMetrics.beginFrame(dt)
    if not profilingEnabled() then
        frameActive = false
        frameStartTime = nil
        return
    end

    ensureSessionStarted()
    frameActive = true
    frameStartTime = nowSeconds()

    summaryTimer = summaryTimer + (dt or 0)

    for name, _ in pairs(sectionTotals) do
        sectionTotals[name] = 0
        sectionStarts[name] = nil
    end
end

function perfMetrics.beginSection(name)
    if not frameActive or not name then
        return
    end

    getOrCreateSectionBuffer(name)
    sectionStarts[name] = nowSeconds()
end

function perfMetrics.endSection(name)
    if not frameActive or not name then
        return 0
    end

    local startedAt = sectionStarts[name]
    if not startedAt then
        return 0
    end

    local elapsedMs = (nowSeconds() - startedAt) * 1000
    sectionStarts[name] = nil
    sectionTotals[name] = (sectionTotals[name] or 0) + elapsedMs

    return elapsedMs
end

local function writeFrameSamples(frameMs)
    local frameRecord = {
        timestamp = nowSeconds(),
        frameIndex = (captureFrames[#captureFrames] and (captureFrames[#captureFrames].frameIndex + 1)) or 1,
        frameMs = frameMs,
        sections = {}
    }

    pushSample(frameBuffer, frameMs)

    for name, buffer in pairs(sectionBuffers) do
        local value = sectionTotals[name] or 0
        pushSample(buffer, value)
        frameRecord.sections[name] = value
    end

    captureFrames[#captureFrames + 1] = frameRecord

    frameWriteIndex = frameWriteIndex + 1
    if frameWriteIndex > RING_SIZE then
        frameWriteIndex = 1
    end

    frameCount = math.min(frameCount + 1, RING_SIZE)
end

function perfMetrics.endFrame()
    if not frameActive or not frameStartTime then
        return
    end

    local frameMs = (nowSeconds() - frameStartTime) * 1000
    writeFrameSamples(frameMs)

    frameStartTime = nil
    frameActive = false

    local config = getPerfConfig()
    if config.ENABLE_PROFILING and summaryTimer >= SUMMARY_INTERVAL_SECONDS then
        summaryTimer = 0
        local snapshot = perfMetrics.getSnapshot()
        logger.info("PERF", string.format(
            "Frame summary: avg %.1fms median %.1fms p95 %.1fms (~%.1f FPS)",
            snapshot.frame.avgMs,
            snapshot.frame.medianMs,
            snapshot.frame.p95Ms,
            snapshot.frame.avgFps
        ))
    end
end

function perfMetrics.getSnapshot()
    local frameValues = collectSamples(frameBuffer)
    local frameAvgMs = average(frameValues)
    local frameMedianMs = percentile(frameValues, 0.5)
    local frameP95Ms = percentile(frameValues, 0.95)
    local frameMaxMs = 0
    local hitchCount = 0
    local hitchThresholdMs = toNumber(getPerfConfig().HITCH_THRESHOLD_MS, 33.0)

    for i = 1, #frameValues do
        local value = frameValues[i]
        if value > frameMaxMs then
            frameMaxMs = value
        end
        if value > hitchThresholdMs then
            hitchCount = hitchCount + 1
        end
    end

    local sections = {}
    for _, name in ipairs(sectionOrder) do
        local values = collectSamples(sectionBuffers[name] or {})
        sections[name] = {
            avgMs = average(values),
            medianMs = percentile(values, 0.5),
            p95Ms = percentile(values, 0.95)
        }
    end

    local avgFps = 0
    if frameAvgMs > 0 then
        avgFps = 1000 / frameAvgMs
    end

    return {
        samples = #frameValues,
        frame = {
            avgMs = frameAvgMs,
            medianMs = frameMedianMs,
            p95Ms = frameP95Ms,
            maxMs = frameMaxMs,
            avgFps = avgFps
        },
        hitch = {
            thresholdMs = hitchThresholdMs,
            count = hitchCount,
            ratio = (#frameValues > 0) and (hitchCount / #frameValues) or 0
        },
        sections = sections
    }
end

function perfMetrics.drawOverlay()
    local config = getPerfConfig()
    if not config.OVERLAY_ENABLED then
        return
    end

    if not (love and love.graphics) then
        return
    end

    local now = nowSeconds()
    if not overlaySnapshot or (now - overlaySnapshotAt) > OVERLAY_REFRESH_INTERVAL then
        overlaySnapshot = perfMetrics.getSnapshot()
        overlaySnapshotAt = now
    end

    local snapshot = overlaySnapshot
    if not snapshot then
        return
    end

    local x = 14
    local y = 14
    local width = 300
    local height = 150

    love.graphics.push("all")
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", x, y, width, height, 6, 6)
    love.graphics.setColor(1, 1, 1, 0.92)
    love.graphics.rectangle("line", x, y, width, height, 6, 6)

    local cursorY = y + 10
    local lineStep = 16

    love.graphics.print(string.format("PERF (samples: %d)", snapshot.samples or 0), x + 10, cursorY)
    cursorY = cursorY + lineStep

    love.graphics.print(
        string.format(
            "Frame avg %.1fms | med %.1f | p95 %.1f",
            snapshot.frame.avgMs,
            snapshot.frame.medianMs,
            snapshot.frame.p95Ms
        ),
        x + 10,
        cursorY
    )
    cursorY = cursorY + lineStep

    love.graphics.print(
        string.format(
            "FPS %.1f | hitch>%dms: %d",
            snapshot.frame.avgFps,
            math.floor(snapshot.hitch.thresholdMs + 0.5),
            snapshot.hitch.count
        ),
        x + 10,
        cursorY
    )
    cursorY = cursorY + lineStep

    for _, sectionName in ipairs(DEFAULT_SECTION_NAMES) do
        local section = snapshot.sections[sectionName]
        if section then
            love.graphics.print(
                string.format(
                    "%s: avg %.1f | p95 %.1f",
                    sectionName,
                    section.avgMs,
                    section.p95Ms
                ),
                x + 10,
                cursorY
            )
            cursorY = cursorY + lineStep
        end
    end

    love.graphics.pop()
end

local function buildSummaryText(snapshot, frameCountValue, endedDate)
    local lines = {
        "# Perf Session Summary",
        "",
        string.format("- Session: `%s`", tostring(sessionName)),
        string.format("- Started: `%s`", tostring(sessionStartedDate or "unknown")),
        string.format("- Ended: `%s`", tostring(endedDate or os.date("%Y-%m-%d %H:%M:%S"))),
        string.format("- Frames: `%d`", frameCountValue),
        "",
        "## Frame",
        string.format("- Avg (ms): `%.3f`", snapshot.frame.avgMs or 0),
        string.format("- Median (ms): `%.3f`", snapshot.frame.medianMs or 0),
        string.format("- P95 (ms): `%.3f`", snapshot.frame.p95Ms or 0),
        string.format("- Max (ms): `%.3f`", snapshot.frame.maxMs or 0),
        string.format("- Avg FPS: `%.3f`", snapshot.frame.avgFps or 0),
        "",
        "## Hitches",
        string.format("- Threshold (ms): `%.2f`", snapshot.hitch.thresholdMs or 33.0),
        string.format("- Count: `%d`", snapshot.hitch.count or 0),
        string.format("- Ratio: `%.4f`", snapshot.hitch.ratio or 0),
        "",
        "## Sections"
    }

    for _, sectionName in ipairs(DEFAULT_SECTION_NAMES) do
        local section = snapshot.sections and snapshot.sections[sectionName]
        if section then
            lines[#lines + 1] = string.format(
                "- `%s`: avg=%.3fms median=%.3fms p95=%.3fms",
                sectionName,
                section.avgMs or 0,
                section.medianMs or 0,
                section.p95Ms or 0
            )
        end
    end

    return table.concat(lines, "\n") .. "\n"
end

local function writeFile(path, content)
    local file, err = io.open(path, "w")
    if not file then
        return false, err
    end
    file:write(content)
    file:close()
    return true
end

function perfMetrics.exportSessionReport()
    local config = getPerfConfig()
    if config.CAPTURE_ENABLED ~= true then
        return nil
    end

    local csvPath = tostring(config.CAPTURE_PATH or "docs/perf_last_session.csv")
    local summaryPath = tostring(config.SUMMARY_PATH or "docs/perf_last_session_summary.txt")
    local endedDate = os.date("%Y-%m-%d %H:%M:%S")
    local snapshot = perfMetrics.getSnapshot()
    local frames = captureFrames or {}

    local csvLines = {
        "timestamp,frame_index,frame_ms,update_ms,draw_ms,ai_turn_ms,grid_draw_ms,ui_draw_ms"
    }
    for i = 1, #frames do
        local frame = frames[i]
        local sections = frame.sections or {}
        csvLines[#csvLines + 1] = string.format(
            "%.6f,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
            frame.timestamp or 0,
            frame.frameIndex or i,
            frame.frameMs or 0,
            sections.update or 0,
            sections.draw or 0,
            sections.ai_turn or 0,
            sections.grid_draw or 0,
            sections.ui_draw or 0
        )
    end

    local okCsv, errCsv = writeFile(csvPath, table.concat(csvLines, "\n") .. "\n")
    if not okCsv then
        logger.warn("PERF", string.format("Unable to write perf CSV '%s': %s", csvPath, tostring(errCsv)))
    end

    local summary = buildSummaryText(snapshot, #frames, endedDate)
    local okSummary, errSummary = writeFile(summaryPath, summary)
    if not okSummary then
        logger.warn("PERF", string.format("Unable to write perf summary '%s': %s", summaryPath, tostring(errSummary)))
    end

    if okCsv and okSummary then
        logger.info("PERF", string.format("Perf session exported: csv=%s summary=%s", csvPath, summaryPath))
    end

    return {
        csvPath = csvPath,
        summaryPath = summaryPath,
        snapshot = snapshot,
        frameCount = #frames
    }
end

function perfMetrics.endSession()
    local report = perfMetrics.exportSessionReport()
    sessionStartedAt = nil
    sessionStartedDate = nil
    return report
end

return perfMetrics
