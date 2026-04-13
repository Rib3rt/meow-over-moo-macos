local onlineLeaderboard = {}

local ConfirmDialog = require("confirmDialog")
local uiTheme = require("uiTheme")
local steamRuntime = require("steam_runtime")
local onlineRatingStore = require("online_rating_store")
local soundCache = require("soundCache")
local os = require("os")

local stateMachineRef = nil
local uiButtons = nil
local buttonOrder = {}
local selectedButtonIndex = 1
local listFocus = true

local leaderboardRows = {}
local selectedRowIndex = 1
local scrollOffsetRows = 0
local playerNameCache = {}

local localPlayerRow = {
    userId = nil,
    score = (((SETTINGS.RATING or SETTINGS.ELO) or {}).DEFAULT_RATING) or 1200,
    rank = nil,
    name = "You"
}

local statusText = "Ready"
local statusSeverity = "info"
local refreshInFlight = false
local updateButtonStates

local scrollbarDragging = false
local scrollbarDragAnchorY = 0
local scrollbarDragAnchorOffset = 0
local lastHoveredButtonIndex = nil

local buttonBeepSound = nil
local buttonClickSound = nil
local BUTTON_BEEP_SOUND_PATH = "assets/audio/GenericButton14.wav"
local BUTTON_CLICK_SOUND_PATH = "assets/audio/GenericButton6.wav"

local LAYOUT = {
    panelMarginX = 40,
    topPanelY = 40,
    topPanelHeight = 76,
    listTop = 130,
    panelBottom = 196,
    listHeaderHeight = 34,
    listPadding = 10,
    listColumnsHeaderHeight = 22,
    rowHeight = 34,
    scrollbarWidth = 12,
    statusBarY = SETTINGS.DISPLAY.HEIGHT - 150,
    statusBarHeight = 36,
    buttonRowY = SETTINGS.DISPLAY.HEIGHT - 100,
    buttonWidth = 210,
    buttonHeight = 50,
    buttonGap = 14
}

local function defaultScore()
    return (((SETTINGS.RATING or SETTINGS.ELO) or {}).DEFAULT_RATING) or 1200
end

local function resolveStoredOnlineRatingSeed()
    local fallback = tonumber(defaultScore()) or 1200
    if onlineRatingStore and type(onlineRatingStore.loadProfile) == "function" then
        local profile = onlineRatingStore.loadProfile()
        if type(profile) == "table" and tonumber(profile.rating) ~= nil then
            return math.floor((tonumber(profile.rating) or fallback) + 0.5)
        end
    end
    return fallback
end

local function initAudio()
    if not buttonBeepSound then
        buttonBeepSound = soundCache.get(BUTTON_BEEP_SOUND_PATH)
        if buttonBeepSound then
            buttonBeepSound:setVolume(SETTINGS.AUDIO.SFX_VOLUME)
        end
    end
    if not buttonClickSound then
        buttonClickSound = soundCache.get(BUTTON_CLICK_SOUND_PATH)
        if buttonClickSound then
            buttonClickSound:setVolume(SETTINGS.AUDIO.SFX_VOLUME)
        end
    end
end

local function playHoverSound()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(BUTTON_BEEP_SOUND_PATH, {
        clone = false,
        volume = SETTINGS.AUDIO.SFX_VOLUME,
        category = "sfx"
    })
end

local function playClickSound()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(BUTTON_CLICK_SOUND_PATH, {
        clone = false,
        volume = SETTINGS.AUDIO.SFX_VOLUME,
        category = "sfx"
    })
end

local function fallbackPlayerName(userId)
    local idText = userId and tostring(userId) or "-"
    return "Player " .. idText:sub(-6)
end

local function nowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.time()
end

local function setStatusBar(textValue, severity)
    statusText = tostring(textValue or "")
    statusSeverity = severity or "info"
end

local function getStatusBarColor()
    if statusSeverity == "error" then
        return 0.78, 0.34, 0.34, 0.95
    end
    if statusSeverity == "warn" then
        return 0.84, 0.72, 0.36, 0.95
    end
    if statusSeverity == "ok" then
        return 0.45, 0.75, 0.55, 0.95
    end
    return 0.72, 0.74, 0.78, 0.95
end

local function listRect()
    local x = LAYOUT.panelMarginX
    local y = LAYOUT.listTop
    local width = SETTINGS.DISPLAY.WIDTH - (LAYOUT.panelMarginX * 2)
    local height = SETTINGS.DISPLAY.HEIGHT - LAYOUT.listTop - LAYOUT.panelBottom
    return x, y, width, height
end

local function listContentRect()
    local x, y, width, height = listRect()
    local contentX = x + LAYOUT.listPadding
    local contentY = y + LAYOUT.listHeaderHeight + LAYOUT.listPadding
    local contentWidth = width - (LAYOUT.listPadding * 2) - LAYOUT.scrollbarWidth - 4
    local contentHeight = height - LAYOUT.listHeaderHeight - (LAYOUT.listPadding * 2)
    return contentX, contentY, contentWidth, contentHeight
end

local function visibleRows()
    local _, _, _, contentHeight = listContentRect()
    local rowsHeight = math.max(0, contentHeight - LAYOUT.listColumnsHeaderHeight)
    return math.max(1, math.floor(rowsHeight / LAYOUT.rowHeight))
end

local function maxScrollOffsetRows()
    return math.max(0, #leaderboardRows - visibleRows())
end

local function clampSelection()
    if #leaderboardRows == 0 then
        selectedRowIndex = 1
        scrollOffsetRows = 0
        return
    end

    if selectedRowIndex < 1 then
        selectedRowIndex = 1
    elseif selectedRowIndex > #leaderboardRows then
        selectedRowIndex = #leaderboardRows
    end

    local visible = visibleRows()
    if selectedRowIndex <= scrollOffsetRows then
        scrollOffsetRows = selectedRowIndex - 1
    elseif selectedRowIndex > scrollOffsetRows + visible then
        scrollOffsetRows = selectedRowIndex - visible
    end

    local maxOffset = maxScrollOffsetRows()
    if scrollOffsetRows < 0 then
        scrollOffsetRows = 0
    elseif scrollOffsetRows > maxOffset then
        scrollOffsetRows = maxOffset
    end
end

local function setSelectedRowIndex(index)
    selectedRowIndex = index
    clampSelection()
end

local function setScrollOffsetRows(offset)
    local maxOffset = maxScrollOffsetRows()
    local nextOffset = math.floor(offset)
    if nextOffset < 0 then
        nextOffset = 0
    elseif nextOffset > maxOffset then
        nextOffset = maxOffset
    end
    scrollOffsetRows = nextOffset
    clampSelection()
end

local function scrollRows(delta)
    setScrollOffsetRows(scrollOffsetRows + delta)
end

local function scrollbarGeometry()
    local x, y, width, height = listRect()
    local trackX = x + width - LAYOUT.listPadding - LAYOUT.scrollbarWidth
    local trackY = y + LAYOUT.listHeaderHeight + LAYOUT.listPadding + LAYOUT.listColumnsHeaderHeight
    local trackHeight = height - LAYOUT.listHeaderHeight - (LAYOUT.listPadding * 2) - LAYOUT.listColumnsHeaderHeight

    local visible = visibleRows()
    local total = #leaderboardRows
    if total <= visible then
        return {
            visible = false,
            trackX = trackX,
            trackY = trackY,
            trackHeight = trackHeight,
            thumbY = trackY,
            thumbHeight = trackHeight
        }
    end

    local maxOffset = maxScrollOffsetRows()
    local thumbHeight = math.max(24, math.floor(trackHeight * (visible / total)))
    local thumbTravel = trackHeight - thumbHeight
    local ratio = maxOffset > 0 and (scrollOffsetRows / maxOffset) or 0
    local thumbY = trackY + math.floor(thumbTravel * ratio)

    return {
        visible = true,
        trackX = trackX,
        trackY = trackY,
        trackHeight = trackHeight,
        thumbY = thumbY,
        thumbHeight = thumbHeight,
        thumbTravel = thumbTravel,
        maxOffset = maxOffset
    }
end

local function rowIndexAt(x, y)
    local contentX, contentY, contentWidth, contentHeight = listContentRect()
    local rowsTopY = contentY + LAYOUT.listColumnsHeaderHeight
    local rowsBottomY = contentY + contentHeight
    if x < contentX or x > contentX + contentWidth then
        return nil
    end
    if y < rowsTopY or y > rowsBottomY then
        return nil
    end

    local row = math.floor((y - rowsTopY) / LAYOUT.rowHeight) + 1
    local index = scrollOffsetRows + row
    if index < 1 or index > #leaderboardRows then
        return nil
    end
    return index
end

local function updateButtonVisuals()
    for i, button in ipairs(buttonOrder) do
        local variant = button.enabled and "default" or "disabled"
        uiTheme.applyButtonVariant(button, variant)
        button.disabledVisual = not button.enabled
        button.focused = (i == selectedButtonIndex and not listFocus and button.enabled)
        button.currentColor = button.focused and button.hoverColor or button.baseColor
    end
end

local function selectEnabledLeaderboardButton(startIndex, delta)
    if #buttonOrder == 0 then
        return nil
    end

    local index = startIndex
    for _ = 1, #buttonOrder do
        if index < 1 then
            index = #buttonOrder
        elseif index > #buttonOrder then
            index = 1
        end
        if buttonOrder[index] and buttonOrder[index].enabled then
            return index
        end
        index = index + delta
    end

    return nil
end

local function ensureValidLeaderboardButtonSelection()
    local resolved = selectEnabledLeaderboardButton(selectedButtonIndex, 1) or selectEnabledLeaderboardButton(1, 1)
    if resolved then
        selectedButtonIndex = resolved
        return true
    end
    return false
end

updateButtonStates = function()
    local onlineReady = steamRuntime.isOnlineReady() == true
    uiButtons.refresh.enabled = onlineReady and not refreshInFlight
    uiButtons.back.enabled = true
    if #leaderboardRows == 0 then
        listFocus = false
    end
    if not listFocus or #leaderboardRows == 0 then
        ensureValidLeaderboardButtonSelection()
    end
    updateButtonVisuals()
end

local function focusLeaderboardButtons()
    listFocus = false
    ensureValidLeaderboardButtonSelection()
    updateButtonStates()
end

local function isMouseOverButton(button, x, y)
    return button and x >= button.x and x <= button.x + button.width and y >= button.y and y <= button.y + button.height
end

local function resolvePlayerName(userId)
    if not userId then
        return "Unknown"
    end

    local key = tostring(userId)
    local cached = playerNameCache[key]
    if cached and cached ~= "" then
        return cached
    end

    local resolved = steamRuntime.getPersonaNameForUser and steamRuntime.getPersonaNameForUser(key) or nil
    if not resolved or resolved == "" then
        resolved = fallbackPlayerName(key)
    end

    playerNameCache[key] = resolved
    return resolved
end

local function buildLocalPlayerRow(leaderboardName, localUserId)
    local row = {
        userId = localUserId,
        score = defaultScore(),
        rank = nil,
        name = "You"
    }

    if not localUserId then
        return row
    end

    local around = steamRuntime.downloadLeaderboardAroundUser(leaderboardName, 0, 0) or {}
    for _, entry in ipairs(around) do
        if tostring(entry.userId or "") == tostring(localUserId) then
            row.score = tonumber(entry.score) or row.score
            row.rank = tonumber(entry.rank)
            return row
        end
    end

    local direct = steamRuntime.downloadLeaderboardEntriesForUsers(leaderboardName, {localUserId}) or {}
    for _, entry in ipairs(direct) do
        if tostring(entry.userId or "") == tostring(localUserId) then
            row.score = tonumber(entry.score) or row.score
            row.rank = tonumber(entry.rank)
            break
        end
    end

    return row
end

local function buildLeaderboardRowFields(row)
    local rankField = row.rank and ("#" .. tostring(row.rank)) or "#-"
    local playerField = tostring(row.name or "Unknown")
    local ratingField = string.format("RATING %d", tonumber(row.score) or defaultScore())
    return {
        rankField = rankField,
        playerField = playerField,
        eloField = ratingField
    }
end


local function refreshLeaderboard()
    if refreshInFlight then
        return
    end

    refreshInFlight = true

    if not steamRuntime.isOnlineReady() then
        leaderboardRows = {}
        localPlayerRow = {
            userId = nil,
            score = defaultScore(),
            rank = nil,
            name = "You"
        }
        setStatusBar("Steam unavailable. Leaderboard disabled.", "warn")
        refreshInFlight = false
        updateButtonStates()
        return
    end

    local leaderboardName = (((SETTINGS.RATING or SETTINGS.ELO) or {}).LEADERBOARD_NAME) or "global_glicko2_v1"
    if steamRuntime.ensureLocalLeaderboardPresence then
        steamRuntime.ensureLocalLeaderboardPresence(leaderboardName, resolveStoredOnlineRatingSeed())
    end
    steamRuntime.findOrCreateLeaderboard(leaderboardName, "descending", "numeric")

    local topRows = steamRuntime.downloadLeaderboardTop(leaderboardName, 1, 100) or {}
    local localUserId = steamRuntime.getLocalUserId()
    localPlayerRow = buildLocalPlayerRow(leaderboardName, localUserId)

    leaderboardRows = {}
    for _, entry in ipairs(topRows) do
        local row = {
            userId = entry.userId,
            rank = tonumber(entry.rank),
            score = tonumber(entry.score) or defaultScore(),
            name = resolvePlayerName(entry.userId)
        }
        leaderboardRows[#leaderboardRows + 1] = row
    end

    playerNameCache[tostring(localUserId or "")] = "You"
    selectedRowIndex = 1
    scrollOffsetRows = 0
    clampSelection()
    if #leaderboardRows == 0 then
        listFocus = false
        ensureValidLeaderboardButtonSelection()
    end

    setStatusBar(string.format("Leaderboard updated: %d rows.", #leaderboardRows), "ok")
    refreshInFlight = false
    updateButtonStates()
end

local function onBack()
    if stateMachineRef then
        stateMachineRef.changeState("mainMenu")
    end
end

local function triggerSelectedButton(button)
    if not button or not button.enabled then
        return
    end

    playClickSound()

    if button == uiButtons.refresh then
        refreshLeaderboard()
    elseif button == uiButtons.back then
        onBack()
    end

    updateButtonStates()
end

local function initializeButtons()
    local count = 2
    local totalWidth = count * LAYOUT.buttonWidth + (count - 1) * LAYOUT.buttonGap
    local startX = math.floor((SETTINGS.DISPLAY.WIDTH - totalWidth) / 2)

    uiButtons = {
        refresh = {
            x = startX,
            y = LAYOUT.buttonRowY,
            width = LAYOUT.buttonWidth,
            height = LAYOUT.buttonHeight,
            text = "Refresh",
            enabled = true,
            currentColor = uiTheme.COLORS.button,
            hoverColor = uiTheme.COLORS.buttonHover,
            pressedColor = uiTheme.COLORS.buttonPressed
        },
        back = {
            x = startX + LAYOUT.buttonWidth + LAYOUT.buttonGap,
            y = LAYOUT.buttonRowY,
            width = LAYOUT.buttonWidth,
            height = LAYOUT.buttonHeight,
            text = "Back",
            enabled = true,
            currentColor = uiTheme.COLORS.button,
            hoverColor = uiTheme.COLORS.buttonHover,
            pressedColor = uiTheme.COLORS.buttonPressed
        }
    }

    buttonOrder = {uiButtons.refresh, uiButtons.back}
    for _, button in ipairs(buttonOrder) do
        uiTheme.applyButtonVariant(button, "default")
    end
end

function onlineLeaderboard.enter(stateMachine)
    stateMachineRef = stateMachine

    initializeButtons()
    selectedButtonIndex = 1
    listFocus = true
    leaderboardRows = {}
    selectedRowIndex = 1
    scrollOffsetRows = 0
    playerNameCache = {}
    refreshInFlight = false
    setStatusBar("Ready", "info")
    scrollbarDragging = false
    lastHoveredButtonIndex = nil

    refreshLeaderboard()
end

function onlineLeaderboard.exit()
    stateMachineRef = nil
    scrollbarDragging = false
end

function onlineLeaderboard.update(dt)
    if ConfirmDialog.isActive() then
        ConfirmDialog.update(dt)
        return
    end

    clampSelection()
    updateButtonStates()
end

function onlineLeaderboard.draw()
    love.graphics.push()
    love.graphics.translate(SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY)
    love.graphics.scale(SETTINGS.DISPLAY.SCALE)

    love.graphics.setColor(uiTheme.COLORS.background)
    love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)

    local topPanelX = LAYOUT.panelMarginX
    local topPanelY = LAYOUT.topPanelY
    local topPanelW = SETTINGS.DISPLAY.WIDTH - (LAYOUT.panelMarginX * 2)
    uiTheme.drawTechPanel(topPanelX, topPanelY, topPanelW, LAYOUT.topPanelHeight)

    local yourRank = localPlayerRow.rank and ("#" .. tostring(localPlayerRow.rank)) or "#-"
    local yourScore = tonumber(localPlayerRow.score) or defaultScore()

    love.graphics.setColor(0.90, 0.88, 0.82, 1)
    love.graphics.printf("Your Position", topPanelX + 12, topPanelY + 8, topPanelW - 24, "left")
    love.graphics.setColor(0.84, 0.92, 0.78, 1)
    love.graphics.printf(localPlayerRow.name or "You", topPanelX + 12, topPanelY + 40, math.floor(topPanelW * 0.55), "left")
    love.graphics.printf(string.format("RATING %d", yourScore), topPanelX + math.floor(topPanelW * 0.56), topPanelY + 40, math.floor(topPanelW * 0.20), "left")
    love.graphics.printf(yourRank, topPanelX + math.floor(topPanelW * 0.78), topPanelY + 40, math.floor(topPanelW * 0.18), "left")

    local panelX, panelY, panelW, panelH = listRect()
    uiTheme.drawTechPanel(panelX, panelY, panelW, panelH)

    love.graphics.setColor(0.90, 0.88, 0.82, 1)
    love.graphics.printf("Top 100", panelX + 12, panelY + 8, panelW - 24, "left")

    local contentX, contentY, contentW, contentH = listContentRect()
    local rowsTopY = contentY + LAYOUT.listColumnsHeaderHeight
    local colRank = math.floor(contentW * 0.14)
    local colPlayer = math.floor(contentW * 0.58)
    local colElo = contentW - (colRank + colPlayer)

    love.graphics.setColor(0.15, 0.16, 0.18, 0.5)
    love.graphics.rectangle("fill", contentX, contentY, contentW, contentH)

    love.graphics.setColor(0.18, 0.20, 0.22, 0.9)
    love.graphics.rectangle("fill", contentX, contentY, contentW, LAYOUT.listColumnsHeaderHeight)
    love.graphics.setColor(0.76, 0.78, 0.82, 1)
    love.graphics.printf("Rank", contentX + 8, contentY + 4, colRank - 10, "left")
    love.graphics.printf("Player", contentX + colRank + 6, contentY + 4, colPlayer - 10, "left")
    love.graphics.printf("RATING", contentX + colRank + colPlayer + 6, contentY + 4, colElo - 10, "left")

    if #leaderboardRows == 0 then
        love.graphics.setColor(0.72, 0.70, 0.66, 1)
        love.graphics.printf("No leaderboard entries available.", contentX + 8, rowsTopY + 10, contentW - 16, "left")
    else
        local visible = visibleRows()
        local startIndex = scrollOffsetRows + 1
        local endIndex = math.min(#leaderboardRows, scrollOffsetRows + visible)
        for i = startIndex, endIndex do
            local row = leaderboardRows[i]
            local rowY = rowsTopY + (i - startIndex) * LAYOUT.rowHeight
            local isSelected = i == selectedRowIndex

            if isSelected then
                if listFocus then
                    love.graphics.setColor(0.30, 0.44, 0.54, 0.9)
                else
                    love.graphics.setColor(0.24, 0.32, 0.38, 0.75)
                end
                love.graphics.rectangle("fill", contentX + 2, rowY + 1, contentW - 4, LAYOUT.rowHeight - 2)
            elseif ((i - startIndex) % 2) == 1 then
                love.graphics.setColor(1, 1, 1, 0.03)
                love.graphics.rectangle("fill", contentX + 2, rowY + 1, contentW - 4, LAYOUT.rowHeight - 2)
            end

            local fields = buildLeaderboardRowFields(row)
            love.graphics.setColor(0.94, 0.92, 0.86, 1)
            love.graphics.printf(fields.rankField, contentX + 8, rowY + 8, colRank - 10, "left")
            love.graphics.printf(fields.playerField, contentX + colRank + 6, rowY + 8, colPlayer - 10, "left")
            love.graphics.printf(fields.eloField, contentX + colRank + colPlayer + 6, rowY + 8, colElo - 10, "left")

            love.graphics.setColor(1, 1, 1, 0.08)
            love.graphics.rectangle("fill", contentX + 2, rowY + LAYOUT.rowHeight - 1, contentW - 4, 1)
        end
    end

    local scrollbar = scrollbarGeometry()
    love.graphics.setColor(0.24, 0.24, 0.24, 0.9)
    love.graphics.rectangle("fill", scrollbar.trackX, scrollbar.trackY, LAYOUT.scrollbarWidth, scrollbar.trackHeight, 4, 4)
    if scrollbar.visible then
        love.graphics.setColor(0.66, 0.67, 0.70, 0.95)
        love.graphics.rectangle("fill", scrollbar.trackX + 1, scrollbar.thumbY + 1, LAYOUT.scrollbarWidth - 2, scrollbar.thumbHeight - 2, 4, 4)
    end

    local statusR, statusG, statusB, statusA = getStatusBarColor()
    love.graphics.setColor(0.12, 0.13, 0.16, 0.92)
    love.graphics.rectangle("fill", panelX, LAYOUT.statusBarY, panelW, LAYOUT.statusBarHeight, 6, 6)
    love.graphics.setColor(statusR, statusG, statusB, statusA)
    love.graphics.rectangle("line", panelX, LAYOUT.statusBarY, panelW, LAYOUT.statusBarHeight, 6, 6)
    love.graphics.setColor(0.95, 0.94, 0.9, 0.98)
    love.graphics.printf(statusText or "", panelX + 10, LAYOUT.statusBarY + 9, panelW - 20, "left")

    for _, button in ipairs(buttonOrder) do
        uiTheme.drawButton(button)
    end

    if ConfirmDialog and ConfirmDialog.draw then
        ConfirmDialog.draw()
    end

    love.graphics.pop()
end

function onlineLeaderboard.mousemoved(x, y, dx, dy, istouch)
    if ConfirmDialog.isActive() then
        ConfirmDialog.mousemoved(x, y)
        return
    end

    local tx = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    if scrollbarDragging then
        local scrollbar = scrollbarGeometry()
        if scrollbar.visible and scrollbar.thumbTravel > 0 and scrollbar.maxOffset > 0 then
            local deltaY = ty - scrollbarDragAnchorY
            local ratio = deltaY / scrollbar.thumbTravel
            local targetOffset = scrollbarDragAnchorOffset + ratio * scrollbar.maxOffset
            setScrollOffsetRows(targetOffset)
        end
        updateButtonStates()
        return
    end

    local hoveredIndex = nil
    for i, button in ipairs(buttonOrder) do
        if button.enabled and isMouseOverButton(button, tx, ty) then
            selectedButtonIndex = i
            listFocus = false
            hoveredIndex = i
        end
    end

    if hoveredIndex and hoveredIndex ~= lastHoveredButtonIndex then
        playHoverSound()
    end
    lastHoveredButtonIndex = hoveredIndex

    updateButtonStates()
end

function onlineLeaderboard.mousepressed(x, y, button, istouch, presses)
    if button ~= 1 then
        return
    end

    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousepressed(x, y, button)
    end

    local tx = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    local scrollbar = scrollbarGeometry()
    if scrollbar.visible then
        local inTrack = tx >= scrollbar.trackX and tx <= scrollbar.trackX + LAYOUT.scrollbarWidth and ty >= scrollbar.trackY and ty <= scrollbar.trackY + scrollbar.trackHeight
        local inThumb = inTrack and ty >= scrollbar.thumbY and ty <= scrollbar.thumbY + scrollbar.thumbHeight

        if inThumb then
            scrollbarDragging = true
            scrollbarDragAnchorY = ty
            scrollbarDragAnchorOffset = scrollOffsetRows
            return
        elseif inTrack then
            if ty < scrollbar.thumbY then
                scrollRows(-visibleRows())
            elseif ty > scrollbar.thumbY + scrollbar.thumbHeight then
                scrollRows(visibleRows())
            end
            updateButtonStates()
            return
        end
    end

    local rowIndex = rowIndexAt(tx, ty)
    if rowIndex then
        setSelectedRowIndex(rowIndex)
        listFocus = true
        updateButtonStates()
        return
    end

    for i, candidate in ipairs(buttonOrder) do
        if candidate.enabled and isMouseOverButton(candidate, tx, ty) then
            selectedButtonIndex = i
            listFocus = false
            lastHoveredButtonIndex = i
            triggerSelectedButton(candidate)
            return
        end
    end

    updateButtonStates()
end

function onlineLeaderboard.mousereleased(x, y, button, istouch, presses)
    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousereleased(x, y, button)
    end

    if button == 1 then
        scrollbarDragging = false
    end
end

function onlineLeaderboard.wheelmoved(dx, dy)
    if ConfirmDialog.isActive() then
        return
    end

    if dy ~= 0 then
        listFocus = true
        scrollRows(-dy)
        updateButtonStates()
    end
end

function onlineLeaderboard.keypressed(key, scancode, isrepeat)
    if ConfirmDialog.isActive() then
        return ConfirmDialog.keypressed(key)
    end

    if key == "escape" then
        onBack()
        return true
    end

    if key == "tab" then
        listFocus = not listFocus
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "up" or key == "w" then
        if not listFocus then
            if #leaderboardRows > 0 then
                listFocus = true
                clampSelection()
                updateButtonStates()
                playHoverSound()
                return true
            end
            return false
        end

        if #leaderboardRows > 0 then
            local nextIndex = selectedRowIndex - 1
            if nextIndex < 1 then
                nextIndex = 1
            end
            if nextIndex ~= selectedRowIndex then
                setSelectedRowIndex(nextIndex)
                updateButtonStates()
                playHoverSound()
            end
            return true
        end
    end

    if key == "down" or key == "s" then
        if not listFocus then
            return true
        end

        if #leaderboardRows > 0 then
            local nextIndex = selectedRowIndex + 1
            if nextIndex > #leaderboardRows then
                focusLeaderboardButtons()
                playHoverSound()
                return true
            end
            setSelectedRowIndex(nextIndex)
            updateButtonStates()
            playHoverSound()
            return true
        end
    end

    if key == "pageup" then
        listFocus = true
        scrollRows(-visibleRows())
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "pagedown" then
        listFocus = true
        scrollRows(visibleRows())
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "left" or key == "a" or key == "q" then
        focusLeaderboardButtons()
        selectedButtonIndex = selectEnabledLeaderboardButton(selectedButtonIndex - 1, -1) or selectedButtonIndex
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "right" or key == "d" or key == "e" then
        focusLeaderboardButtons()
        selectedButtonIndex = selectEnabledLeaderboardButton(selectedButtonIndex + 1, 1) or selectedButtonIndex
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "return" or key == "space" then
        if not listFocus then
            triggerSelectedButton(buttonOrder[selectedButtonIndex])
            updateButtonStates()
            return true
        end
    end

    return false
end

function onlineLeaderboard.gamepadpressed(joystick, button)
    if button == "a" then
        return onlineLeaderboard.keypressed("return", "return", false)
    end
    if button == "b" or button == "back" then
        return onlineLeaderboard.keypressed("escape", "escape", false)
    end
    if button == "dpup" then
        return onlineLeaderboard.keypressed("up", "up", false)
    end
    if button == "dpdown" then
        return onlineLeaderboard.keypressed("down", "down", false)
    end
    if button == "dpleft" or button == "leftshoulder" then
        return onlineLeaderboard.keypressed("left", "left", false)
    end
    if button == "dpright" or button == "rightshoulder" then
        return onlineLeaderboard.keypressed("right", "right", false)
    end
    return false
end

return onlineLeaderboard
