package.path = package.path .. ";./?.lua"

local results = {}

local function runTest(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = {name = name, ok = ok, err = err}
end

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s (expected=%s actual=%s)", message or "assertEquals failed", tostring(expected), tostring(actual)), 2)
    end
end

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = deepCopy(v)
    end
    return copy
end

local function setupGlobals()
    _G.SETTINGS = {
        PERF = {
            ENABLE_PROFILING = false,
            OVERLAY_ENABLED = false,
            LOG_LEVEL = "warn",
            LOG_CATEGORIES = {
                AI = false,
                GAMEPLAY = false,
                GRID = false,
                UI = false,
                PERF = false
            },
            DRAW_CACHE_ENABLED = true,
            WRAP_CACHE_ENABLED = true
        },
        DISPLAY = {
            WIDTH = 1280,
            HEIGHT = 800,
            SCALE = 1,
            OFFSETX = 0,
            OFFSETY = 0
        },
        FONT = {
            INFO_SIZE = 16,
            BIG_SIZE = 32,
            TITLE_SIZE = 24
        },
        AUDIO = {
            SFX = false,
            SFX_VOLUME = 0
        }
    }

    _G.GAME = {
        CONSTANTS = {
            TILE_SIZE = 90,
            GRID_ORIGIN_X = 100,
            GRID_ORIGIN_Y = 60,
            GRID_WIDTH = 720,
            GRID_HEIGHT = 720,
            GRID_SIZE = 8
        },
        MODE = {
            MULTYPLAYER_LOCAL = "local"
        },
        CURRENT = {}
    }

    _G.DEBUG = {AI = false, UI = false}
end

local function makeLoveStub()
    local canvasCreateCount = 0
    local currentCanvas = nil
    local currentFont = nil

    local defaultFont = {
        getWrap = function(self, text)
            return #tostring(text), {tostring(text)}
        end,
        getWidth = function(self, text)
            return #tostring(text) * 8
        end,
        getHeight = function()
            return 16
        end
    }

    local graphics = {
        newCanvas = function(width, height)
            canvasCreateCount = canvasCreateCount + 1
            return {
                width = width,
                height = height,
                release = function() end,
                getWidth = function(self) return self.width end,
                getHeight = function(self) return self.height end
            }
        end,
        getCanvas = function()
            return currentCanvas
        end,
        setCanvas = function(canvas)
            currentCanvas = canvas
        end,
        clear = function() end,
        setColor = function() end,
        setFont = function(font)
            currentFont = font
        end,
        getFont = function()
            return currentFont or defaultFont
        end,
        print = function() end,
        printf = function() end,
        rectangle = function() end,
        setLineWidth = function() end,
        setScissor = function() end,
        getDimensions = function()
            return SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT
        end,
        push = function() end,
        pop = function() end,
        draw = function() end,
        newShader = function()
            return {
                send = function() end
            }
        end,
        newImage = function()
            return {
                getWidth = function() return 64 end,
                getHeight = function() return 64 end
            }
        end
    }

    local audio = {
        newSource = function()
            return {
                setVolume = function() end,
                seek = function() end,
                play = function() end
            }
        end
    }

    _G.love = {
        graphics = graphics,
        audio = audio,
        timer = {getTime = function() return 1 end}
    }

    return {
        getCanvasCreateCount = function()
            return canvasCreateCount
        end,
        defaultFont = defaultFont
    }
end

runTest("tile_variant_cache_deterministic", function()
    setupGlobals()
    makeLoveStub()

    package.loaded["playGridClass"] = nil
    local playGridClass = require("playGridClass")

    local grid = setmetatable({rows = 8, cols = 8}, playGridClass)
    grid:rebuildTileVariantCache()
    local first = deepCopy(grid.tileVariantByCell)

    grid.tileVariantByCell = {}
    grid:rebuildTileVariantCache()

    for row = 1, 8 do
        for col = 1, 8 do
            assertEquals(
                grid.tileVariantByCell[row][col],
                first[row][col],
                string.format("tile variant mismatch at (%d,%d)", row, col)
            )
        end
    end
end)

runTest("logger_disabled_fastpath_no_string_formatting", function()
    setupGlobals()
    makeLoveStub()

    package.loaded["logger"] = nil
    local logger = require("logger")

    local printed = 0
    local oldPrint = _G.print
    _G.print = function()
        printed = printed + 1
    end

    local tostringCalls = 0
    local payload = setmetatable({}, {
        __tostring = function()
            tostringCalls = tostringCalls + 1
            return "payload"
        end
    })

    logger.debug("AI", payload)

    _G.print = oldPrint

    assertEquals(printed, 0, "disabled debug logger should not print")
    assertEquals(tostringCalls, 0, "disabled debug logger should not format payload")
end)

runTest("highlight_dirty_key_skips_rebuild_when_unchanged", function()
    local file = io.open("gameplay.lua", "r")
    assertTrue(file ~= nil, "unable to open gameplay.lua")
    local content = file:read("*a")
    file:close()

    assertTrue(content:find("lastSetupHighlightKey", 1, true) ~= nil, "missing setup highlight dirty key cache")
    assertTrue(content:find("if key == lastSetupHighlightKey", 1, true) ~= nil, "missing unchanged-key short circuit")
end)

runTest("gamelog_wrap_cache_hits_on_stable_viewport", function()
    setupGlobals()
    local loveStub = makeLoveStub()

    local wrapCalls = 0
    local mockFont = {
        getWrap = function(self, text)
            wrapCalls = wrapCalls + 1
            return #tostring(text), {tostring(text)}
        end,
        getWidth = function(self, text)
            return #tostring(text) * 8
        end,
        getHeight = function()
            return 16
        end
    }

    package.loaded["fontCache"] = {
        get = function()
            return mockFont
        end
    }

    package.loaded["gameLogViewer"] = nil
    local viewer = require("gameLogViewer")

    local ruler = {
        turnLog = {
            "P1 moved Cloudstriker",
            "P2 attacked Bastion",
            "P1 deployed Artillery"
        }
    }

    viewer.show(ruler)
    viewer.draw()
    local firstPass = wrapCalls
    viewer.draw()
    local secondPass = wrapCalls

    assertTrue(firstPass > 0, "first draw should compute wraps")
    assertEquals(secondPass, firstPass, "second draw should reuse wrap cache on stable viewport")
end)

runTest("draw_coordinate_canvas_rebuilds_only_on_resize", function()
    setupGlobals()
    local loveStub = makeLoveStub()

    package.loaded["playGridClass"] = nil
    local playGridClass = require("playGridClass")

    local grid = setmetatable({rows = 8, cols = 8}, playGridClass)
    grid.coordinateLabelsCanvas = nil
    grid.coordinateLabelCacheKey = nil

    local first = grid:ensureCoordinateLabelCanvas()
    local firstCount = loveStub.getCanvasCreateCount()
    local second = grid:ensureCoordinateLabelCanvas()
    local secondCount = loveStub.getCanvasCreateCount()

    assertTrue(first ~= nil, "first coordinate label canvas should be created")
    assertEquals(second, first, "cached coordinate canvas should be reused")
    assertEquals(secondCount, firstCount, "canvas should not rebuild when display is unchanged")

    SETTINGS.DISPLAY.WIDTH = SETTINGS.DISPLAY.WIDTH + 10
    local third = grid:ensureCoordinateLabelCanvas()
    local thirdCount = loveStub.getCanvasCreateCount()

    assertTrue(third ~= nil, "canvas should be recreated after resize")
    assertTrue(third ~= second, "resized canvas should replace previous canvas")
    assertTrue(thirdCount > secondCount, "canvas rebuild count should increase on resize")
end)

runTest("perf_capture_exports_csv_and_summary", function()
    setupGlobals()
    makeLoveStub()

    local csvPath = "/tmp/perf_smoke_capture.csv"
    local summaryPath = "/tmp/perf_smoke_capture_summary.txt"
    os.remove(csvPath)
    os.remove(summaryPath)

    SETTINGS.PERF.CAPTURE_ENABLED = true
    SETTINGS.PERF.CAPTURE_PATH = csvPath
    SETTINGS.PERF.SUMMARY_PATH = summaryPath

    package.loaded["perf_metrics"] = nil
    local perfMetrics = require("perf_metrics")

    perfMetrics.startSession("perf_smoke")
    for _ = 1, 4 do
        perfMetrics.beginFrame(0.016)
        perfMetrics.beginSection("update")
        perfMetrics.endSection("update")
        perfMetrics.beginSection("draw")
        perfMetrics.endSection("draw")
        perfMetrics.endFrame()
    end

    local report = perfMetrics.endSession()
    assertTrue(report ~= nil, "expected perf report to be returned")

    local csv = io.open(csvPath, "r")
    assertTrue(csv ~= nil, "expected capture CSV output")
    local csvText = csv:read("*a")
    csv:close()

    local summary = io.open(summaryPath, "r")
    assertTrue(summary ~= nil, "expected capture summary output")
    local summaryText = summary:read("*a")
    summary:close()

    assertTrue(csvText:find("frame_index", 1, true) ~= nil, "CSV header missing")
    assertTrue(summaryText:find("Perf Session Summary", 1, true) ~= nil, "summary title missing")

    os.remove(csvPath)
    os.remove(summaryPath)
end)

runTest("perf_capture_defaults_disabled_in_globals", function()
    local file = io.open("globals.lua", "r")
    assertTrue(file ~= nil, "unable to open globals.lua")
    local content = file:read("*a")
    file:close()

    assertTrue(content:find("CAPTURE_ENABLED = false", 1, true) ~= nil, "perf capture should default to false")
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
    end
end

print("# Perf Smoke Report")
print("")
print("- Passed: " .. tostring(passed))
print("- Failed: " .. tostring(#results - passed))
print("")
for _, result in ipairs(results) do
    local status = result.ok and "PASS" or "FAIL"
    print(string.format("- `%s` %s", status, result.name))
    if not result.ok then
        print("  - Error: " .. tostring(result.err))
    end
end

local failed = #results - passed
os.exit((failed == 0) and 0 or 1)
