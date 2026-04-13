@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PROJECT_ROOT=%SCRIPT_DIR%..\..\.."
set "REDIST_DIR=%PROJECT_ROOT%\integrations\steam\redist\win64"
set "LOG_FILE=%APPDATA%\LOVE\MeowOverMoo\SteamRuntimeError.log"

if not exist "%REDIST_DIR%\steam_bridge_native.dll" (
  echo [ERROR] Missing %REDIST_DIR%\steam_bridge_native.dll
  exit /b 1
)
if not exist "%REDIST_DIR%\steam_api64.dll" (
  echo [ERROR] Missing %REDIST_DIR%\steam_api64.dll
  exit /b 1
)

if exist "%REDIST_DIR%\lua51.dll" (
  echo [ERROR] Found %REDIST_DIR%\lua51.dll
  echo [ERROR] Remove it. Native bridge must bind to LOVE's lua51.dll runtime.
  exit /b 1
)
if exist "%REDIST_DIR%\luajit.dll" (
  echo [ERROR] Found %REDIST_DIR%\luajit.dll
  echo [ERROR] Remove it. Native bridge must bind to LOVE's lua51.dll runtime.
  exit /b 1
)

set "PATH=%REDIST_DIR%;%PATH%"

echo [INFO] Steam redist path injected: %REDIST_DIR%
echo [INFO] Launching LOVE with project: %PROJECT_ROOT%
echo [INFO] Runtime log path: %LOG_FILE%

del "%LOG_FILE%" >nul 2>nul

if exist "%ProgramFiles%\LOVE\love.exe" (
  "%ProgramFiles%\LOVE\love.exe" "%PROJECT_ROOT%"
  goto :after_run
)

if exist "%ProgramFiles(x86)%\LOVE\love.exe" (
  "%ProgramFiles(x86)%\LOVE\love.exe" "%PROJECT_ROOT%"
  goto :after_run
)

echo [ERROR] love.exe not found in Program Files.
echo [HINT] Install LOVE 11.5 x64 or launch manually after setting PATH.
exit /b 1

:after_run
echo.
if exist "%LOG_FILE%" (
  echo [INFO] Steam runtime log:
  type "%LOG_FILE%"
) else (
  echo [WARN] Log not found at %LOG_FILE%
)

exit /b %ERRORLEVEL%
