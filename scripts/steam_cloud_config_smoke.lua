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

local checklist = readFile("docs/steam_backend_setup_checklist.md")
assertContains(checklist, "WinAppDataRoaming", "backend checklist")
assertContains(checklist, "LOVE/MeowOverMoo", "backend checklist")
assertContains(checklist, "ScenarioProgress.dat", "backend checklist")
assertContains(checklist, "OnlineRatingProfile.dat", "backend checklist")
assertContains(checklist, "MacAppSupport", "backend checklist")
assertContains(checklist, "LinuxXdgDataHome", "backend checklist")
assertContains(checklist, "Root Overrides", "backend checklist")
assertContains(checklist, "do not configure separate OS-specific root paths", "backend checklist")

local handoff = readFile("docs/release_handoff_2026-05-06.md")
assertContains(handoff, "Root Overrides", "release handoff")
assertContains(handoff, "ScenarioProgress.dat", "release handoff")
assertContains(handoff, "love/MeowOverMoo", "release handoff")

print("steam_cloud_config_smoke: OK")
