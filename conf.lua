require("globals")

function love.conf(t)
	t.title = 'Meow Over Moo!' 				-- The title show in the window title bar
	t.version = '12.0'					 	-- The native Apple Silicon build targets the pinned LOVE 12 runtime line
	t.console = false				 	 	-- Attach a console (boolean, Windows only)
	t.identity = 'MeowOverMoo'								-- LÖVE save identity (logs/settings path)
	t.window.icon = 'assets/app_icon_macos.png'			-- Native desktop/window icon
	t.window.width = SETTINGS.DISPLAY.WIDTH			 		-- The window width resolution
    t.window.height = SETTINGS.DISPLAY.HEIGHT	 			    -- The window height resolution
	t.window.minwidth = SETTINGS.DISPLAY.MINWIDTH		 			-- Minimum window width if the window is resizable
	t.window.minheight = SETTINGS.DISPLAY.MINHEIGHT					-- Minimum window height if the window is resizable
end
