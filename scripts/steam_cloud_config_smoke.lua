local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        error("missing file: " .. tostring(path), 2)
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function assertContains(content, needle, label)
    if not content:find(needle, 1, true) then
        error((label or "content") .. " missing: " .. needle, 2)
    end
end

local function assertNotContains(content, needle, label)
    if content:find(needle, 1, true) then
        error((label or "content") .. " should not contain: " .. needle, 2)
    end
end

local handoff = readFile("HANDOFF.md")
assertContains(handoff, "WinAppDataRoaming", "release handoff")
assertContains(handoff, "| `WinAppDataRoaming` | `MeowOverMoo` | `OnlineRatingProfile.dat` | `No` |", "release handoff")
assertNotContains(handoff, "| `WinAppDataRoaming` | `LOVE/MeowOverMoo`", "release handoff")
assertContains(handoff, "Root Overrides", "release handoff")
assertContains(handoff, "ScenarioProgress.dat", "release handoff")
assertContains(handoff, "OnlineRatingProfile.dat", "release handoff")
assertContains(handoff, "LOVE/MeowOverMoo", "release handoff")
assertContains(handoff, "MacAppSupport", "release handoff")
assertContains(handoff, "LinuxXdgDataHome", "release handoff")
assertContains(handoff, "Do not create separate per-OS Auto-Cloud roots", "release handoff")
assertContains(handoff, "love/MeowOverMoo", "release handoff")

local windowsPackager = readFile("scripts/build_fused_windows_package.py")
assertContains(windowsPackager, "subdirectory MeowOverMoo", "windows package upload instructions")
assertNotContains(windowsPackager, "subdirectory LOVE/MeowOverMoo", "windows package upload instructions")

print("steam_cloud_config_smoke: OK")
