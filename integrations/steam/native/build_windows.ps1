param(
    [string]$SteamSdkRoot = "",
    [string]$OutDir = "",
    [string]$LoveRoot = "",
    [string]$LuaIncludeDir = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDir "../../..")).Path

if ([string]::IsNullOrWhiteSpace($SteamSdkRoot)) {
    $SteamSdkRoot = Join-Path $ProjectRoot "integrations/steam/sdk"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $ProjectRoot "integrations/steam/redist/win64"
}
if ([string]::IsNullOrWhiteSpace($LoveRoot)) {
    if ($env:LOVE_ROOT) {
        $LoveRoot = $env:LOVE_ROOT
    } elseif (Test-Path (Join-Path $env:ProgramFiles "LOVE\love.exe")) {
        $LoveRoot = Join-Path $env:ProgramFiles "LOVE"
    } elseif (Test-Path (Join-Path ${env:ProgramFiles(x86)} "LOVE\love.exe")) {
        $LoveRoot = Join-Path ${env:ProgramFiles(x86)} "LOVE"
    }
}
if ([string]::IsNullOrWhiteSpace($LuaIncludeDir)) {
    if ($env:LUA_INCLUDE_DIR) {
        $LuaIncludeDir = $env:LUA_INCLUDE_DIR
    } elseif (Test-Path (Join-Path $LoveRoot "include\lua.h")) {
        $LuaIncludeDir = Join-Path $LoveRoot "include"
    }
}

if (-not (Test-Path (Join-Path $SteamSdkRoot "public/steam/steam_api.h"))) {
    throw "Steamworks headers not found. Expected $SteamSdkRoot/public/steam/steam_api.h"
}
if ([string]::IsNullOrWhiteSpace($LoveRoot) -or -not (Test-Path (Join-Path $LoveRoot "love.exe"))) {
    throw "LOVE root not found. Pass -LoveRoot or set LOVE_ROOT (expected love.exe)."
}
if (-not (Test-Path (Join-Path $LoveRoot "lua51.dll"))) {
    throw "LOVE lua51.dll not found at $(Join-Path $LoveRoot "lua51.dll")"
}
if ([string]::IsNullOrWhiteSpace($LuaIncludeDir) -or -not (Test-Path (Join-Path $LuaIncludeDir "lua.h"))) {
    throw "Lua headers not found. Pass -LuaIncludeDir (Lua 5.1-compatible headers)."
}

if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw "cl.exe not found. Run from a Visual Studio Developer PowerShell."
}
if (-not (Get-Command lib.exe -ErrorAction SilentlyContinue)) {
    throw "lib.exe not found. Run from a Visual Studio Developer PowerShell."
}
if (-not (Get-Command dumpbin.exe -ErrorAction SilentlyContinue)) {
    throw "dumpbin.exe not found. Run from a Visual Studio Developer PowerShell."
}

if ($env:VSCMD_ARG_TGT_ARCH -and $env:VSCMD_ARG_TGT_ARCH -ne "x64") {
    throw "Wrong VS toolchain arch '$($env:VSCMD_ARG_TGT_ARCH)'. Use x64 Native Tools prompt."
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$BuildTmp = Join-Path $ScriptDir ".build_win"
New-Item -ItemType Directory -Path $BuildTmp -Force | Out-Null

$LoveLuaDll = Join-Path $LoveRoot "lua51.dll"
$LuaDefFile = Join-Path $BuildTmp "lua51_love.def"
$LuaImportLib = Join-Path $BuildTmp "lua51_love.lib"

$ExportDump = & dumpbin.exe /nologo /exports $LoveLuaDll 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read exports from LOVE lua51.dll"
}

$LuaSymbols = @()
foreach ($line in $ExportDump) {
    if ($line -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+([^\s]+)\s*$') {
        $symbol = $matches[1]
        if (-not [string]::IsNullOrWhiteSpace($symbol)) {
            $LuaSymbols += $symbol
        }
    }
}
$LuaSymbols = $LuaSymbols | Sort-Object -Unique
if ($LuaSymbols.Count -eq 0) {
    throw "Could not parse Lua exports from LOVE lua51.dll"
}

$DefLines = @("LIBRARY lua51.dll", "EXPORTS") + ($LuaSymbols | ForEach-Object { "    $_" })
Set-Content -Path $LuaDefFile -Value $DefLines -Encoding ascii

& lib.exe /nologo /def:$LuaDefFile /machine:x64 /out:$LuaImportLib
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $LuaImportLib)) {
    throw "Failed generating import lib from LOVE lua51.dll exports"
}

$Sources = @(
    (Join-Path $ScriptDir "steam_bridge.cpp"),
    (Join-Path $ScriptDir "lua_exports.cpp")
)

$IncludeFlags = @(
    "/I$LuaIncludeDir",
    "/I$SteamSdkRoot/public"
)

$SteamLibDir = Join-Path $SteamSdkRoot "redistributable_bin/win64"
$OutDll = Join-Path $OutDir "steam_bridge_native.dll"

$LinkArgs = @(
    "/OUT:$OutDll",
    "/MACHINE:X64",
    "/EXPORT:luaopen_steam_bridge_native",
    "/LIBPATH:$SteamLibDir",
    "/LIBPATH:$BuildTmp",
    "steam_api64.lib",
    "lua51_love.lib"
)

& cl.exe /nologo /std:c++17 /EHsc /O2 /MT /LD $Sources $IncludeFlags /link $LinkArgs
if ($LASTEXITCODE -ne 0) {
    throw "MSVC build failed with exit code $LASTEXITCODE"
}

$SteamApiDll = Join-Path $SteamLibDir "steam_api64.dll"
if (Test-Path $SteamApiDll) {
    Copy-Item $SteamApiDll (Join-Path $OutDir "steam_api64.dll") -Force
}

foreach ($staleLua in @("lua51.dll", "luajit.dll")) {
    $stalePath = Join-Path $OutDir $staleLua
    if (Test-Path $stalePath) {
        Remove-Item $stalePath -Force
        Write-Host "Removed stale Lua runtime from output: $stalePath"
    }
}

$OutExportDump = & dumpbin.exe /nologo /exports $OutDll 2>&1
if ($LASTEXITCODE -ne 0 -or -not ($OutExportDump -match 'luaopen_steam_bridge_native')) {
    throw "Post-build export check failed: luaopen_steam_bridge_native not exported"
}

$OutImportDump = & dumpbin.exe /nologo /imports $OutDll 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Post-build import check failed: cannot read imports"
}
if (-not ($OutImportDump -match 'steam_api64\.dll')) {
    throw "Post-build import check failed: steam_api64.dll import missing"
}
if (-not ($OutImportDump -match 'lua51\.dll')) {
    throw "Post-build import check failed: lua51.dll import missing"
}

Write-Host "Built: $OutDll"
Write-Host "Using LOVE runtime from: $LoveRoot"
Write-Host "Using Lua headers from: $LuaIncludeDir"
