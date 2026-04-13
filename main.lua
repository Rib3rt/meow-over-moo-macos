-- Keep LuaJIT in interpreter mode on Apple Silicon until the native macOS
-- runtime has full parity with the shipping Windows/Linux builds.
if love and love.system and love.system.getOS and jit and (jit.arch == 'arm64' or jit.arch == 'arm') then
    local okOs, osName = pcall(love.system.getOS)
    if okOs and (osName == "OS X" or osName == "macOS") then
        jit.off()
    end
end

require("globals")

local state_machine = require("stateMachine")
local steamRuntime = require("steam_runtime")
local debugConsoleLog = require("debug_console_log")
local audioRuntime = require("audio_runtime")
local achievementRuntime = require("achievement_runtime")

function love.load()
    debugConsoleLog.init()
    audioRuntime.init()
    achievementRuntime.init()
    steamRuntime.init()
    state_machine.changeState("initialize")
    -- Enable key repeat so holding arrow keys continuously sends keypress events
    if love.keyboard and love.keyboard.setKeyRepeat then
        love.keyboard.setKeyRepeat(true)
    end
end

function love.update(dt)
    steamRuntime.update(dt)
    state_machine.update(dt)
end

function love.draw()
    state_machine.draw()
end

function love.resize(w, h)
    state_machine.resize(w, h)
end

-- Input

-- Mouse
function love.mousemoved(x, y, dx, dy, istouch)
    state_machine.mousemoved(x, y, dx, dy, istouch)
end

function love.mousepressed(x, y, button, istouch, presses)
    state_machine.mousepressed(x, y, button, istouch, presses)
end

function love.mousereleased(x, y, button, istouch, presses)
    state_machine.mousereleased(x, y, button, istouch, presses)
end

function love.wheelmoved(x, y)
    if state_machine.wheelmoved then
        state_machine.wheelmoved(x, y)
    end
end

-- Touch
function love.touchpressed(id, x, y, dx, dy, pressure)
    state_machine.touchpressed(id, x, y, dx, dy, pressure)
end

function love.touchmoved(id, x, y, dx, dy, pressure)
    state_machine.touchmoved(id, x, y, dx, dy, pressure)
end

function love.touchreleased(id, x, y, dx, dy, pressure)
    state_machine.touchreleased(id, x, y, dx, dy, pressure)
end

-- Keyboard
function love.keypressed(key, scancode, isrepeat)
    state_machine.keypressed(key, scancode, isrepeat)
end

function love.keyreleased(key, scancode)
    state_machine.keyreleased(key, scancode)
end

function love.gamepadpressed(joystick, button)
    state_machine.gamepadpressed(joystick, button)
end

function love.gamepadreleased(joystick, button)
    state_machine.gamepadreleased(joystick, button)
end

function love.gamepadaxis(joystick, axis, value)
    state_machine.gamepadaxis(joystick, axis, value)
end

function love.joystickpressed(joystick, button)
    state_machine.joystickpressed(joystick, button)
end

function love.joystickreleased(joystick, button)
    state_machine.joystickreleased(joystick, button)
end

function love.joystickaxis(joystick, axis, value)
    state_machine.joystickaxis(joystick, axis, value)
end

function love.joystickhat(joystick, hat, direction)
    state_machine.joystickhat(joystick, hat, direction)
end

function love.joystickremoved(joystick)
    state_machine.joystickremoved(joystick)
end

function love.quit()
    achievementRuntime.flush()
    steamRuntime.shutdown()
end


function love.focus(focused)
    local regained = audioRuntime.onFocusChanged(focused)
    if regained == true then
        audioRuntime.resumeAudioOutput("focus_regained")
        audioRuntime.logRemotePlayWindowSummary("focus_regained")
    end
end

function love.visible(visible)
    local regained = audioRuntime.onVisibilityChanged(visible)
    if regained == true then
        audioRuntime.resumeAudioOutput("visibility_regained")
        audioRuntime.logRemotePlayWindowSummary("visibility_regained")
    end
end
