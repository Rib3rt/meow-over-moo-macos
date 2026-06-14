require("globals")

local function detectConfigOS()
    if love and love.system and love.system.getOS then
        return love.system.getOS()
    end
    if jit and jit.os == "OSX" then
        return "OS X"
    end
    return jit and jit.os or nil
end

local function shouldStartFullscreen(osName)
    return osName == "Linux" or osName == "SteamOS" or osName == "iOS" or osName == "Android"
end

function love.conf(t)
    local startFullscreen = shouldStartFullscreen(detectConfigOS())
	t.title = 'Meow Over Moo!' 				-- The title show in the window title bar
	t.version = '12.0'					 	-- The native Apple Silicon build targets the pinned LOVE 12 runtime line
	t.console = false				 	 	-- Attach a console (boolean, Windows only)
	t.identity = 'MeowOverMoo'								-- LÖVE save identity (logs/settings path)
	t.window.icon = 'assets/app_icon_macos.png'			-- Native desktop/window icon
	t.window.width = SETTINGS.DISPLAY.WIDTH			 		-- The window width resolution
    t.window.height = SETTINGS.DISPLAY.HEIGHT	 			    -- The window height resolution
	t.window.minwidth = SETTINGS.DISPLAY.MINWIDTH		 			-- Minimum window width if the window is resizable
	t.window.minheight = SETTINGS.DISPLAY.MINHEIGHT					-- Minimum window height if the window is resizable
	t.window.fullscreen = startFullscreen
	t.window.fullscreentype = SETTINGS.DISPLAY.FULLSCREEN_TYPE or "desktop"
	t.window.resizable = not startFullscreen
	t.window.borderless = startFullscreen
end
