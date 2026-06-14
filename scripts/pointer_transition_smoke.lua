package.path = package.path .. ";./?.lua"

local scenarioPresses = 0
local sameStatePresses = 0
local sameStateReleases = 0
local sameStateTouchPresses = 0
local sameStateTouchReleases = 0
local sameStateMode = false
local stateMachineRef = nil

SETTINGS = {
    FEATURES = {
        SCENARIO_MODE = true
    },
    INPUT = {
        TOUCH_PRIMARY_ONLY = true
    }
}

GAME = {
    CURRENT = {},
    MODE = {
        MULTYPLAYER_LOCAL = "local"
    }
}

MOUSE_STATE = {
    IS_HIDDEN = false
}

love = {
    graphics = {
        getDimensions = function()
            return 1000, 1000
        end
    },
    mouse = {
        setVisible = function() end
    }
}

local function emptyState()
    return {}
end

package.preload.initialize = emptyState
package.preload.gameplay = emptyState
package.preload.factionSelect = emptyState
package.preload.onlineLobby = emptyState
package.preload.onlineLeaderboard = emptyState
package.preload.scenarioEditor = emptyState
package.preload.scenarioGameplay = emptyState

package.preload.mainMenu = function()
    return {
        enter = function(stateMachine)
            stateMachineRef = stateMachine
        end,
        mousepressed = function()
            if sameStateMode then
                sameStatePresses = sameStatePresses + 1
                return true
            end
            stateMachineRef.changeState("scenarioSelect")
            return true
        end,
        mousereleased = function()
            if sameStateMode then
                sameStateReleases = sameStateReleases + 1
                return true
            end
            return nil
        end,
        touchpressed = function()
            sameStateTouchPresses = sameStateTouchPresses + 1
            return true
        end,
        touchreleased = function()
            sameStateTouchReleases = sameStateTouchReleases + 1
            return true
        end
    }
end

package.preload.scenarioSelect = function()
    return {
        mousepressed = function()
            scenarioPresses = scenarioPresses + 1
            stateMachineRef.changeState("scenarioGameplay")
            return true
        end
    }
end

package.preload.input_bindings = function()
    return {}
end

package.preload.steam_runtime = function()
    return {
        shutdownSteamInput = function() end,
        isOnlineReady = function()
            return false
        end
    }
end

package.preload.confirmDialog = function()
    return {
        isActive = function()
            return false
        end
    }
end

package.preload.input_backend = function()
    return {
        isSteamInputEligibleState = function()
            return false
        end
    }
end

package.preload.audio_runtime = function()
    return {
        playGameplayMusic = function() end,
        playMenuMusic = function() end,
        setMusicDucked = function() end,
        logRemotePlayWindowSummary = function() end
    }
end

package.preload.rendering_quality = function()
    return {
        roundToPhysicalPixel = function(value)
            return value
        end
    }
end

local stateMachine = require("stateMachine")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
    end
end

local function resetToMainMenu()
    scenarioPresses = 0
    sameStatePresses = 0
    sameStateReleases = 0
    sameStateTouchPresses = 0
    sameStateTouchReleases = 0
    sameStateMode = false
    stateMachine.changeState("mainMenu")
    assertEqual(stateMachine.getCurrentStateName(), "mainMenu", "reset state")
end

resetToMainMenu()
stateMachine.mousepressed(10, 10, 1, true, 1)
assertEqual(stateMachine.getCurrentStateName(), "scenarioSelect", "mouse press should open scenario list")
stateMachine.touchpressed("finger-mouse-first", 0.01, 0.01, 0, 0, 1)
assertEqual(stateMachine.getCurrentStateName(), "scenarioSelect", "duplicate touch press must not start gameplay")
assertEqual(scenarioPresses, 0, "duplicate touch press should not hit scenario rows")
stateMachine.touchreleased("finger-mouse-first", 0.01, 0.01, 0, 0, 1)
stateMachine.mousepressed(10, 10, 1, true, 1)
assertEqual(stateMachine.getCurrentStateName(), "scenarioGameplay", "next intentional press should start gameplay")
stateMachine.mousereleased(10, 10, 1, true, 1)

resetToMainMenu()
stateMachine.touchpressed("finger-touch-first", 0.01, 0.01, 0, 0, 1)
assertEqual(stateMachine.getCurrentStateName(), "scenarioSelect", "touch press should open scenario list")
stateMachine.mousepressed(10, 10, 1, true, 1)
assertEqual(stateMachine.getCurrentStateName(), "scenarioSelect", "duplicate mouse press must not start gameplay")
assertEqual(scenarioPresses, 0, "duplicate mouse press should not hit scenario rows")
stateMachine.touchreleased("finger-touch-first", 0.01, 0.01, 0, 0, 1)

resetToMainMenu()
sameStateMode = true
stateMachine.touchpressed("finger-same-state", 0.01, 0.01, 0, 0, 1)
assertEqual(sameStatePresses, 1, "touch press should execute one same-state action")
assertEqual(sameStateTouchPresses, 0, "touch press must route only through mousepressed")
stateMachine.mousepressed(10, 10, 1, true, 1)
assertEqual(sameStatePresses, 1, "duplicate touch mouse press must not repeat same-state action")
stateMachine.touchreleased("finger-same-state", 0.01, 0.01, 0, 0, 1)
assertEqual(sameStateReleases, 1, "touch release should execute one same-state mouse release")
assertEqual(sameStateTouchReleases, 0, "touch release must route only through mousereleased")
stateMachine.mousereleased(10, 10, 1, true, 1)
assertEqual(sameStateReleases, 1, "duplicate touch mouse release must not repeat same-state release")
stateMachine.mousepressed(10, 10, 1, true, 1)
assertEqual(sameStatePresses, 2, "new press after release should execute same-state action")

print("# Pointer Transition Smoke Report")
print("")
print("- Passed: 3")
print("- Failed: 0")
