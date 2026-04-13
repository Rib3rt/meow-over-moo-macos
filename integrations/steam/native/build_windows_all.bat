@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PROJECT_ROOT=%SCRIPT_DIR%..\..\.."
set "OUT_DIR=%PROJECT_ROOT%\integrations\steam\redist\win64"

set "LUA_ROOT=%~1"
if "%LUA_ROOT%"=="" set "LUA_ROOT=%LUAJIT_ROOT%"
if "%LUA_ROOT%"=="" set "LUA_ROOT=C:\Users\mirod\Desktop\LuaJIT-For-Windows"
set "LUA_INCLUDE_DIR=%LUA_ROOT%\include"

set "LOVE_ROOT=%~2"
if "%LOVE_ROOT%"=="" set "LOVE_ROOT=%LOVE_ROOT_ENV%"
if "%LOVE_ROOT%"=="" set "LOVE_ROOT=%ProgramFiles%\LOVE"

where cl >nul 2>nul
if errorlevel 1 goto :no_cl

if "%LOVE_ROOT%"=="" goto :no_love
if not exist "%LOVE_ROOT%\love.exe" goto :no_love
if not exist "%LOVE_ROOT%\lua51.dll" goto :no_lua_dll
if not exist "%LUA_INCLUDE_DIR%\lua.h" goto :no_lua_headers

echo.
echo [INFO] Building Steam bridge (LOVE 11.5 ABI)...
echo [INFO] LOVE root: %LOVE_ROOT%
echo [INFO] Lua headers: %LUA_INCLUDE_DIR%
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_windows.ps1" -LoveRoot "%LOVE_ROOT%" -LuaIncludeDir "%LUA_INCLUDE_DIR%"
if errorlevel 1 goto :build_failed

echo.
echo [INFO] Verifying output files...
if not exist "%OUT_DIR%\steam_bridge_native.dll" goto :missing_bridge
if not exist "%OUT_DIR%\steam_api64.dll" goto :missing_steamapi
if exist "%OUT_DIR%\lua51.dll" goto :stale_lua51
if exist "%OUT_DIR%\luajit.dll" goto :stale_luajit

echo [OK] Build completed.
echo [OK] Output folder: %OUT_DIR%
echo.

where dumpbin >nul 2>nul
if errorlevel 1 goto :done

echo [INFO] Export check:
dumpbin /exports "%OUT_DIR%\steam_bridge_native.dll" | findstr /i "luaopen_steam_bridge_native"

echo [INFO] Import check:
dumpbin /imports "%OUT_DIR%\steam_bridge_native.dll" | findstr /i "steam_api64.dll lua51.dll"

goto :done

:no_cl
echo [ERROR] cl.exe not found. Open "x64 Native Tools Command Prompt for VS" first.
exit /b 1

:no_love
echo [ERROR] LOVE root not found or invalid.
echo [HINT] Pass second arg explicitly, e.g. "C:\Program Files\LOVE"
exit /b 1

:no_lua_dll
echo [ERROR] LOVE lua51.dll missing at: %LOVE_ROOT%\lua51.dll
exit /b 1

:no_lua_headers
echo [ERROR] Lua headers missing at: %LUA_INCLUDE_DIR%\lua.h
echo [HINT] Pass first arg as Lua headers root (e.g. LuaJIT-for-Windows).
exit /b 1

:build_failed
echo [ERROR] Build failed.
exit /b 1

:missing_bridge
echo [ERROR] Missing: %OUT_DIR%\steam_bridge_native.dll
exit /b 1

:missing_steamapi
echo [ERROR] Missing: %OUT_DIR%\steam_api64.dll
exit /b 1

:stale_lua51
echo [ERROR] Unexpected lua51.dll in output folder: %OUT_DIR%\lua51.dll
echo [ERROR] Remove it. Bridge must use LOVE runtime lua51.dll.
exit /b 1

:stale_luajit
echo [ERROR] Unexpected luajit.dll in output folder: %OUT_DIR%\luajit.dll
echo [ERROR] Remove it. Bridge must use LOVE runtime lua51.dll.
exit /b 1

:done
exit /b 0
