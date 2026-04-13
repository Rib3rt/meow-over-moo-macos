@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PROJECT_ROOT=%SCRIPT_DIR%..\..\.."
set "REDIST_DIR=%PROJECT_ROOT%\integrations\steam\redist\win64"
set "LOG_FILE=%APPDATA%\LOVE\MeowOverMoo\SteamRuntimeError.log"
if "%~1"=="" (
  if not defined LOVE_ROOT set "LOVE_ROOT="
) else (
  set "LOVE_ROOT=%~1"
)
if "%LOVE_ROOT%"=="" if exist "%ProgramFiles%\LOVE\love.exe" set "LOVE_ROOT=%ProgramFiles%\LOVE"
if "%LOVE_ROOT%"=="" if exist "%ProgramFiles(x86)%\LOVE\love.exe" set "LOVE_ROOT=%ProgramFiles(x86)%\LOVE"

echo [DIAG] Project root: %PROJECT_ROOT%
echo [DIAG] Redist dir:   %REDIST_DIR%
echo [DIAG] LOVE root:    %LOVE_ROOT%
echo [DIAG] Log file:     %LOG_FILE%
echo.

where dumpbin >nul 2>nul
if errorlevel 1 (
  echo [ERROR] dumpbin not available in current shell.
  echo [HINT] Run from "x64 Native Tools Command Prompt for VS".
  exit /b 1
)

if not exist "%REDIST_DIR%\steam_bridge_native.dll" (
  echo [ERROR] Missing %REDIST_DIR%\steam_bridge_native.dll
  exit /b 1
)
if not exist "%REDIST_DIR%\steam_api64.dll" (
  echo [ERROR] Missing %REDIST_DIR%\steam_api64.dll
  exit /b 1
)
if "%LOVE_ROOT%"=="" (
  echo [ERROR] LOVE root unresolved. Pass as first arg.
  exit /b 1
)
if not exist "%LOVE_ROOT%\lua51.dll" (
  echo [ERROR] Missing %LOVE_ROOT%\lua51.dll
  exit /b 1
)

echo [DIAG] 1) Bridge exports
dumpbin /exports "%REDIST_DIR%\steam_bridge_native.dll" | findstr /i "luaopen_steam_bridge_native"

echo.
echo [DIAG] 2) Bridge imports
dumpbin /imports "%REDIST_DIR%\steam_bridge_native.dll" | findstr /i "steam_api64.dll lua51.dll"

echo.
echo [DIAG] 3) LOVE lua51 exports (sample)
dumpbin /exports "%LOVE_ROOT%\lua51.dll" | findstr /i "luaL_register lua_gettop lua_pcall"

echo.
echo [DIAG] 4) Active Steam runtime log
if exist "%LOG_FILE%" (
  type "%LOG_FILE%"
) else (
  echo [WARN] No log found yet at %LOG_FILE%
)

exit /b 0
