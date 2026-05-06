local gameplay = require("gameplay")

local scenarioGameplay = {}

local function resolveScenarioReturnState()
    local configured = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO_RETURN_STATE or nil
    if type(configured) == "string" and configured ~= "" then
        return configured
    end
    return "scenarioSelect"
end

local function scenarioTrace(message)
    print("[SCENARIO_TRACE][ScenarioGameplay] " .. tostring(message or ""))
end

local function snapshotSummary(snapshot)
    local counts = {
        total = 0,
        blue = 0,
        red = 0,
        neutral = 0,
        activeRed = 0,
        redCommandants = 0
    }
    for _, unit in ipairs(snapshot and snapshot.boardUnits or {}) do
        local player = tonumber(unit.player)
        local name = tostring(unit.name or "")
        counts.total = counts.total + 1
        if player == 1 then
            counts.blue = counts.blue + 1
        elseif player == 2 then
            counts.red = counts.red + 1
            if name == "Commandant" then
                counts.redCommandants = counts.redCommandants + 1
            else
                counts.activeRed = counts.activeRed + 1
            end
        else
            counts.neutral = counts.neutral + 1
        end
    end
    return string.format(
        "units=%d blue=%d red=%d activeRed=%d redCommandants=%d neutral=%d",
        counts.total,
        counts.blue,
        counts.red,
        counts.activeRed,
        counts.redCommandants,
        counts.neutral
    )
end

-- SCENARIO-ONLY WRAPPER:
-- This state exists only to enter gameplay with GAME.MODE.SCENARIO.
-- Do not add generic gameplay behavior here.
function scenarioGameplay.enter(stateMachine)
    if GAME and GAME.CURRENT then
        GAME.CURRENT.MODE = GAME.MODE.SCENARIO
    end
    local scenario = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
    scenarioTrace(string.format(
        "enter id=%s source=%s %s",
        tostring(scenario and scenario.id or ""),
        tostring(scenario and scenario.sourcePath or ""),
        snapshotSummary(scenario and scenario.snapshot or nil)
    ))
    return gameplay.enter(stateMachine, resolveScenarioReturnState(), {
        scenario = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
    })
end

function scenarioGameplay.exit()
    if gameplay.exit then
        return gameplay.exit()
    end
end

function scenarioGameplay.update(dt)
    if gameplay.update then
        return gameplay.update(dt)
    end
end

function scenarioGameplay.draw()
    if gameplay.draw then
        return gameplay.draw()
    end
end

function scenarioGameplay.resize(w, h)
    if gameplay.resize then
        return gameplay.resize(w, h)
    end
end

function scenarioGameplay.mousemoved(x, y, dx, dy, istouch)
    if gameplay.mousemoved then
        return gameplay.mousemoved(x, y, dx, dy, istouch)
    end
end

function scenarioGameplay.mousepressed(x, y, button, istouch, presses)
    if gameplay.mousepressed then
        return gameplay.mousepressed(x, y, button, istouch, presses)
    end
end

function scenarioGameplay.mousereleased(x, y, button, istouch, presses)
    if gameplay.mousereleased then
        return gameplay.mousereleased(x, y, button, istouch, presses)
    end
end

function scenarioGameplay.wheelmoved(dx, dy)
    if gameplay.wheelmoved then
        return gameplay.wheelmoved(dx, dy)
    end
end

function scenarioGameplay.touchpressed(id, x, y, dx, dy, pressure)
    if gameplay.touchpressed then
        return gameplay.touchpressed(id, x, y, dx, dy, pressure)
    end
end

function scenarioGameplay.touchmoved(id, x, y, dx, dy, pressure)
    if gameplay.touchmoved then
        return gameplay.touchmoved(id, x, y, dx, dy, pressure)
    end
end

function scenarioGameplay.touchreleased(id, x, y, dx, dy, pressure)
    if gameplay.touchreleased then
        return gameplay.touchreleased(id, x, y, dx, dy, pressure)
    end
end

function scenarioGameplay.keypressed(key, scancode, isrepeat)
    if gameplay.keypressed then
        return gameplay.keypressed(key, scancode, isrepeat)
    end
end

function scenarioGameplay.keyreleased(key, scancode)
    if gameplay.keyreleased then
        return gameplay.keyreleased(key, scancode)
    end
end

function scenarioGameplay.gamepadpressed(joystick, button)
    if gameplay.gamepadpressed then
        return gameplay.gamepadpressed(joystick, button)
    end
end

function scenarioGameplay.gamepadreleased(joystick, button)
    if gameplay.gamepadreleased then
        return gameplay.gamepadreleased(joystick, button)
    end
end

function scenarioGameplay.gamepadaxis(joystick, axis, value)
    if gameplay.gamepadaxis then
        return gameplay.gamepadaxis(joystick, axis, value)
    end
end

function scenarioGameplay.joystickpressed(joystick, button)
    if gameplay.joystickpressed then
        return gameplay.joystickpressed(joystick, button)
    end
end

function scenarioGameplay.joystickreleased(joystick, button)
    if gameplay.joystickreleased then
        return gameplay.joystickreleased(joystick, button)
    end
end

function scenarioGameplay.joystickaxis(joystick, axis, value)
    if gameplay.joystickaxis then
        return gameplay.joystickaxis(joystick, axis, value)
    end
end

function scenarioGameplay.joystickhat(joystick, hat, direction)
    if gameplay.joystickhat then
        return gameplay.joystickhat(joystick, hat, direction)
    end
end

return scenarioGameplay
