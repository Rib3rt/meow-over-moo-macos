-- randomGenerator.lua
-- Centralized random number generator with proper seeding and state management

local randomGenerator = {}

-- Internal state
local isInitialized = false
local globalSeed = nil
local rngState = {}

-- High-quality random number generator using multiple entropy sources
function randomGenerator.initialize()
    if isInitialized then
        return -- Already initialized, don't re-seed
    end
    
    -- Collect multiple entropy sources
    local currentTime
    if love and love.timer then
        currentTime = love.timer.getTime()
    else
        currentTime = (os and os.clock and os.clock()) or (os and os.time and os.time()) or 1
    end
    local baseSeed = math.floor(currentTime * 1000000) -- Use full microsecond precision
    
    -- Memory address entropy (using table creation)
    local memTable = {}
    local memoryAddress = tostring(memTable)
    local memoryEntropy = 0
    for i = 1, #memoryAddress do
        memoryEntropy = memoryEntropy + string.byte(memoryAddress, i) * i
    end
    
    -- Frame count entropy if available
    local frameEntropy = 0
    if love and love.graphics and love.graphics.getStats then
        local stats = love.graphics.getStats()
        frameEntropy = (stats.drawcalls or 0) + (stats.canvasswitches or 0)
    end
    
    -- Additional entropy from os.clock if available (not in LÖVE)
    local clockEntropy = 0
    if os and os.clock then
        clockEntropy = math.floor(os.clock() * 1000000)
    end
    
    -- Fallback entropy using string hashing
    local fallbackEntropy = 0
    local timeStr = tostring(currentTime)
    for i = 1, #timeStr do
        fallbackEntropy = fallbackEntropy + string.byte(timeStr, i) * (i * 31)
    end
    
    -- Combine all entropy sources with prime number mixing
    globalSeed = baseSeed
        + memoryEntropy * 2654435761  -- Large prime
        + frameEntropy * 1597334677   -- Another large prime
        + clockEntropy * 2246822519   -- Another large prime
        + fallbackEntropy * 3266489917 -- Another large prime
    
    -- Additional mixing with Linear Congruential Generator constants
    globalSeed = globalSeed * 1664525 + 1013904223
    globalSeed = globalSeed % 4294967296 -- Keep within 32-bit range
    
    -- Initialize Lua's built-in RNG once
    math.randomseed(globalSeed)
    
    -- Warm up the generator with variable number of calls
    local warmupCalls = (globalSeed % 50) + 20
    for i = 1, warmupCalls do
        math.random()
    end
    
    isInitialized = true
end

-- Get a random number between 0 and 1
function randomGenerator.random()
    if not isInitialized then
        randomGenerator.initialize()
    end
    return math.random()
end

-- Get a random integer between min and max (inclusive)
function randomGenerator.randomInt(min, max)
    if not isInitialized then
        randomGenerator.initialize()
    end
    
    if not min then
        return math.random()
    elseif not max then
        return math.random(min)
    else
        return math.random(min, max)
    end
end

-- Get a deterministic random number based on a seed (for consistent results)
-- This creates a temporary generator state without affecting the global state
function randomGenerator.deterministicRandom(seed, min, max)
    -- Use a simple LCG for deterministic results
    local a = 1664525
    local c = 1013904223
    local m = 4294967296
    
    -- Mix the seed better to avoid similar inputs producing similar outputs
    seed = (seed * 2654435761) % m  -- Multiply by large prime for better distribution
    
    -- Generate next value in sequence
    local nextValue = (a * seed + c) % m
    local normalized = nextValue / m
    
    if not min then
        return normalized
    elseif not max then
        return math.floor(normalized * min) + 1
    else
        return math.floor(normalized * (max - min + 1)) + min
    end
end

-- Get the current seed (for debugging)
function randomGenerator.getSeed()
    return globalSeed
end

-- Force re-initialization (use sparingly)
function randomGenerator.forceReinitialize()
    isInitialized = false
    randomGenerator.initialize()
end

-- Create a position-based deterministic seed for UI elements
function randomGenerator.createPositionSeed(x, y, extraFactor)
    extraFactor = extraFactor or 1
    return (x * 1000 + y * 100 + extraFactor) % 4294967296
end

-- Get deterministic flip type for UI elements (maintains visual consistency)
function randomGenerator.getFlipType(x, y, extraFactor)
    local seed = randomGenerator.createPositionSeed(x, y, extraFactor)
    return randomGenerator.deterministicRandom(seed, 1, 4)
end

return randomGenerator
