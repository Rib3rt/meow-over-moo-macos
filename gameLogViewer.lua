local fontCache = require("fontCache")
local uiTheme = require("uiTheme")
local soundCache = require("soundCache")

local MONOGRAM_FONT_PATH = "assets/fonts/monogram-extended.ttf"

local function getMonogramFont(size)
    return fontCache.get(MONOGRAM_FONT_PATH, size)
end

local gameLogViewer = {}

-- Close button (bottom-center)
local closeButton = {
    width = 120,
    height = 36,
    x = 0,
    y = 0,
    hovered = false,
    focused = false,
}

-- Focus management: defocus while scrolling; refocus after inactivity
local refocusTimer = 0
local REFOCUS_DELAY = 0.25
local lastInput = "keyboard" -- or "mouse"

--------------------------------------------------
-- LOCAL VARIABLES
--------------------------------------------------
local isVisible = false
local scrollPosition = 0
local lineHeight = 18
local padding = 20
local maxVisibleLines = 0
local totalLines = 0
local gameRuler = nil
local wrapCache = {}
local wrapCacheOrder = {}
local WRAP_CACHE_LIMIT = 1200

-- Audio for scroll
local scrollSound = nil
local buttonFocusSound = nil
local SCROLL_SOUND_PATH = "assets/audio/GenericButton14.wav"
local BUTTON_FOCUS_SOUND_PATH = "assets/audio/GenericButton14.wav"
local activeScrollSoundPath = SCROLL_SOUND_PATH
local scrollbarFlashTimer = 0
local holdDir = 0              -- -1 for up, +1 for down, 0 for none
local holdTimer = 0            -- countdown timer for next auto-scroll tick
local holdInitialDelay = 0.25  -- seconds before auto-repeat starts
local holdRepeatInterval = 0.06-- seconds between auto-scroll ticks
local function getMaxScroll()
    return math.max(0, totalLines - maxVisibleLines)
end

local function clampScroll(value)
    local maxScroll = getMaxScroll()
    if maxScroll == 0 then
        return 0
    end
    return math.max(0, math.min(maxScroll, value))
end

local function makeWrapCacheKey(entryIndex, text, contentWidth, fontSize)
    return table.concat({
        tostring(entryIndex),
        tostring(math.floor(contentWidth)),
        tostring(fontSize),
        tostring(text or "")
    }, "|")
end

local function getWrappedLines(logFont, entryIndex, text, contentWidth)
    if not logFont then
        return {tostring(text or "")}
    end

    local perfConfig = SETTINGS and SETTINGS.PERF or {}
    local cacheEnabled = perfConfig.WRAP_CACHE_ENABLED ~= false
    local key = makeWrapCacheKey(entryIndex, text, contentWidth, SETTINGS.FONT.INFO_SIZE)

    if cacheEnabled then
        local cached = wrapCache[key]
        if cached then
            return cached.lines
        end
    end

    local _, lines = logFont:getWrap(text, contentWidth)
    if #lines == 0 then
        lines = {tostring(text or "")}
    end

    if cacheEnabled then
        wrapCache[key] = {lines = lines}
        wrapCacheOrder[#wrapCacheOrder + 1] = key
        if #wrapCacheOrder > WRAP_CACHE_LIMIT then
            local stale = table.remove(wrapCacheOrder, 1)
            if stale then
                wrapCache[stale] = nil
            end
        end
    end

    return lines
end
local function initAudio()
    if scrollSound then return end
    scrollSound = soundCache.get(SCROLL_SOUND_PATH)
    activeScrollSoundPath = SCROLL_SOUND_PATH
    buttonFocusSound = soundCache.get(BUTTON_FOCUS_SOUND_PATH)
    if SETTINGS and SETTINGS.AUDIO and SETTINGS.AUDIO.SFX_VOLUME then
        if scrollSound then scrollSound:setVolume(SETTINGS.AUDIO.SFX_VOLUME) end
        if buttonFocusSound then buttonFocusSound:setVolume(SETTINGS.AUDIO.SFX_VOLUME) end
    end
end

local function playScrollSound()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(activeScrollSoundPath, {
        clone = false,
        volume = SETTINGS.AUDIO.SFX_VOLUME,
        category = "sfx"
    })
end

local function playButtonFocusSound()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(BUTTON_FOCUS_SOUND_PATH, {
        clone = false,
        volume = SETTINGS.AUDIO.SFX_VOLUME,
        category = "sfx"
    })
end

-- Toggle for scissor clipping; set to true if scissor math is verified for all transforms
local USE_SCISSOR = false

-- UI colors matching the game's style
local UI_COLORS = {
    background = uiTheme.COLORS.background,
    border = uiTheme.COLORS.border,
    text = uiTheme.COLORS.text,
    highlight = uiTheme.COLORS.highlight,
    scrollbar = {108/255, 88/255, 66/255, 0.7},
    scrollbarHover = {128/255, 108/255, 86/255, 0.9},
    row1 = {0.20, 0.16, 0.13, 0.35},                -- Alternating row background 1
    row2 = {0.24, 0.19, 0.15, 0.35},                -- Alternating row background 2
}

-- Dialog dimensions and position
local dialog = {
    width = 560,
    height = 520,
    x = 0,
    y = 0,
    scrollbar = {
        width = 12,
        isHovered = false,
        isDragging = false,
        dragOffsetY = 0
    }
}

--------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------
local function updateDialogPosition()
    -- Keep function for completeness; position will be recalculated in draw() each frame
    local transformedWidth = SETTINGS.DISPLAY.WIDTH / SETTINGS.DISPLAY.SCALE
    local transformedHeight = SETTINGS.DISPLAY.HEIGHT / SETTINGS.DISPLAY.SCALE
    dialog.x = (transformedWidth - dialog.width) / 2
    dialog.y = (transformedHeight - dialog.height) / 2
    local reserved = 70
    maxVisibleLines = math.floor((dialog.height - padding * 2 - reserved) / lineHeight)
end

local function drawTechPanel(x, y, width, height)
    uiTheme.drawTechPanel(x, y, width, height)
end

local function drawScrollBar()
    if totalLines <= maxVisibleLines then return end -- No need for scrollbar
    
    local scrollbar = dialog.scrollbar
    local trackHeight = dialog.height - padding * 2
    local thumbHeight = math.max(40, (maxVisibleLines / totalLines) * trackHeight)
    local maxScroll = totalLines - maxVisibleLines
    local thumbY = dialog.y + padding + (scrollPosition / maxScroll) * (trackHeight - thumbHeight)
    
    -- Draw scrollbar track
    love.graphics.setColor(UI_COLORS.highlight)
    love.graphics.rectangle("fill", 
        dialog.x + dialog.width - padding - scrollbar.width, 
        dialog.y + padding, 
        scrollbar.width, 
        trackHeight,
        4
    )
    
    -- Draw scrollbar thumb
    local isHoverOrFlash = scrollbar.isHovered or (scrollbarFlashTimer and scrollbarFlashTimer > 0)
    love.graphics.setColor(isHoverOrFlash and UI_COLORS.scrollbarHover or UI_COLORS.scrollbar)
    love.graphics.rectangle("fill", 
        dialog.x + dialog.width - padding - scrollbar.width, 
        thumbY, 
        scrollbar.width, 
        thumbHeight,
        4
    )
end

--------------------------------------------------
-- PUBLIC FUNCTIONS
--------------------------------------------------

function gameLogViewer.show(ruler)
    gameRuler = ruler
    isVisible = true
    scrollPosition = 0
    initAudio()
    updateDialogPosition()
    totalLines = #gameRuler.turnLog
    -- Auto focus behavior depends on last input method
    if lastInput == "mouse" then
        -- Compute button layout to evaluate hover
        closeButton.x = dialog.x + (dialog.width - closeButton.width) / 2
        closeButton.y = dialog.y + dialog.height - padding - closeButton.height
        local mx, my = love.mouse.getPosition()
        local transformedX = (mx - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
        local transformedY = (my - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
        closeButton.hovered = (transformedX >= closeButton.x and transformedX <= closeButton.x + closeButton.width and
                               transformedY >= closeButton.y and transformedY <= closeButton.y + closeButton.height)
        closeButton.focused = closeButton.hovered
        if closeButton.focused then
            playButtonFocusSound()
        end
    else
        closeButton.focused = true
        playButtonFocusSound()
    end
    refocusTimer = 0
    wrapCache = {}
    wrapCacheOrder = {}
end

function gameLogViewer.hide()
    isVisible = false
end

function gameLogViewer.isActive()
    return isVisible
end

function gameLogViewer.draw()
    if not isVisible or not gameRuler then return end
    
    -- Update total lines in case new messages were added
    totalLines = #gameRuler.turnLog
    
    -- Recompute dialog position using universal coordinates (like confirmDialog)
    local actualWidth, actualHeight = love.graphics.getDimensions()
    local transformedWidth = actualWidth / SETTINGS.DISPLAY.SCALE
    local transformedHeight = actualHeight / SETTINGS.DISPLAY.SCALE
    transformedWidth = transformedWidth - (SETTINGS.DISPLAY.OFFSETX * 2 / SETTINGS.DISPLAY.SCALE)
    transformedHeight = transformedHeight - (SETTINGS.DISPLAY.OFFSETY * 2 / SETTINGS.DISPLAY.SCALE)
    dialog.x = (transformedWidth - dialog.width) / 2
    dialog.y = (transformedHeight - dialog.height) / 2
    
    -- Dynamically recompute visible lines based on current size
    local reserved = 70 -- 40 for title + 30 for footer
    maxVisibleLines = math.max(1, math.floor((dialog.height - padding * 2 - reserved) / lineHeight))
    
    -- Darkened overlay (covers entire screen like ConfirmDialog)
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)
    
    -- Draw the main panel
    drawTechPanel(dialog.x, dialog.y, dialog.width, dialog.height)
    
    -- Set up scissor for text area (disabled until transform-safe)
    local scissorX = dialog.x + padding
    local scissorY = dialog.y + padding + 40  -- leave space for title (approx 40px)
    local scissorWidth = dialog.width - padding * 2 - dialog.scrollbar.width - 5
    local scissorHeight = dialog.height - padding * 2 - 70 -- reserve space for title (40) and footer (30)
    if USE_SCISSOR then
        love.graphics.setScissor(
            scissorX * SETTINGS.DISPLAY.SCALE + SETTINGS.DISPLAY.OFFSETX,
            scissorY * SETTINGS.DISPLAY.SCALE + SETTINGS.DISPLAY.OFFSETY,
            scissorWidth * SETTINGS.DISPLAY.SCALE,
            scissorHeight * SETTINGS.DISPLAY.SCALE
        )
    end
    
    -- Draw log entries
    love.graphics.setColor(UI_COLORS.text)
    local logFont = getMonogramFont(SETTINGS.FONT.INFO_SIZE)
    love.graphics.setFont(logFont)
    
    local y = dialog.y + padding + 40
    -- Oldest-first view: start at entry 1 and scroll down to newer entries
    local contentWidth = dialog.width - padding * 3 - dialog.scrollbar.width
    local total = #gameRuler.turnLog
    local maxScroll = math.max(0, total - maxVisibleLines)
    if scrollPosition > maxScroll then scrollPosition = maxScroll end
    if scrollPosition < 0 then scrollPosition = 0 end

    local startIndex = 1 + scrollPosition
    local endIndex = math.min(total, startIndex + maxVisibleLines - 1)
    local row = 0
    for idx = startIndex, endIndex do
        local text = gameRuler.turnLog[idx]
        local lines = getWrappedLines(logFont, idx, text, contentWidth)
        local linecount = #lines
        local rowHeight = math.max(lineHeight, lineHeight * linecount)

        -- Alternating row background for readability
        local rowColor = (row % 2 == 0) and UI_COLORS.row1 or UI_COLORS.row2
        love.graphics.setColor(rowColor)
        love.graphics.rectangle(
            "fill",
            dialog.x + padding,
            y - 2,
            contentWidth,
            rowHeight
        )

        -- Restore text color for the log line
        love.graphics.setColor(UI_COLORS.text)
        for lineIndex = 1, linecount do
            love.graphics.print(
                lines[lineIndex],
                dialog.x + padding,
                y + (lineIndex - 1) * lineHeight
            )
        end

        y = y + rowHeight
        row = row + 1
    end
    
    -- Reset scissor if it was enabled
    if USE_SCISSOR then
        love.graphics.setScissor()
    end
    
    -- Draw scrollbar
    drawScrollBar()
    
    -- Draw title
    love.graphics.setColor(UI_COLORS.text)
    local titleFont = getMonogramFont(SETTINGS.FONT.TITLE_SIZE)
    love.graphics.setFont(titleFont)
    love.graphics.printf("GAME LOG", 
        dialog.x, 
        dialog.y + padding, 
        dialog.width, 
        "center")

    -- Layout Close button at bottom-center
    closeButton.x = dialog.x + (dialog.width - closeButton.width) / 2
    closeButton.y = dialog.y + dialog.height - padding - closeButton.height

    -- While scrolling via keyboard hold, mouse wheel (refocusTimer > 0), or dragging, suppress active visuals
    local temporarilyDefocused = (holdDir ~= 0) or (refocusTimer and refocusTimer > 0) or dialog.scrollbar.isDragging

    -- If focused or hovered, brighten background (unless temporarily defocused)
    local isActiveBtn = (closeButton.focused or closeButton.hovered) and not temporarilyDefocused
    uiTheme.applyButtonVariant(closeButton, "default")
    closeButton.text = "Close"
    closeButton.focused = isActiveBtn
    closeButton.currentColor = isActiveBtn and closeButton.hoverColor or closeButton.baseColor
    closeButton.textOffsetY = math.floor((closeButton.height - logFont:getHeight()) / 2)
    love.graphics.setFont(logFont)
    uiTheme.drawButton(closeButton)
end

function gameLogViewer.mousemoved(x, y)
    lastInput = "mouse"
    if not isVisible then return end
    
    -- Transform coordinates to account for scaling and offset
    local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
    
    -- Check if mouse is over scrollbar
    local scrollbar = dialog.scrollbar
    local isOverScrollbar = transformedX >= dialog.x + dialog.width - padding - scrollbar.width and
                           transformedX <= dialog.x + dialog.width - padding and
                           transformedY >= dialog.y + padding and
                           transformedY <= dialog.y + dialog.height - padding
    
    scrollbar.isHovered = isOverScrollbar
    
    -- Update button hover (transform applied already)
    local wasHovered = closeButton.hovered
    closeButton.hovered = (transformedX >= closeButton.x and transformedX <= closeButton.x + closeButton.width and
                           transformedY >= closeButton.y and transformedY <= closeButton.y + closeButton.height)
    -- On first hover, give focus and play button sound (if not currently defocused due to scrolling)
    if closeButton.hovered and not wasHovered and refocusTimer <= 0 and not dialog.scrollbar.isDragging then
        if not closeButton.focused then
            closeButton.focused = true
            playButtonFocusSound()
        end
    end

    -- If using mouse and not hovering the button, ensure it's not focused
    if lastInput == "mouse" and not dialog.scrollbar.isDragging then
        if refocusTimer <= 0 and not closeButton.hovered and closeButton.focused then
            closeButton.focused = false
        end
    end

    -- Handle scrollbar dragging
    if scrollbar.isDragging then
        local before = scrollPosition
        local trackHeight = dialog.height - padding * 2
        local thumbHeight = math.max(40, (maxVisibleLines / totalLines) * trackHeight)
        local maxScroll = getMaxScroll()
        
        -- Calculate new scroll position based on mouse Y position
        local relativeY = (transformedY - dialog.y - padding - scrollbar.dragOffsetY)
        local scrollRatioDenominator = math.max(1, trackHeight - thumbHeight)
        local scrollRatio = math.max(0, math.min(1, relativeY / scrollRatioDenominator))
        local targetScroll = math.floor(scrollRatio * maxScroll + 0.5)
        if maxScroll == 0 then
            targetScroll = 0
        end
        scrollPosition = targetScroll
        if scrollPosition ~= before then
            scrollbarFlashTimer = 0.2
            closeButton.focused = false
            refocusTimer = REFOCUS_DELAY
            playScrollSound()
        end
    end
end

function gameLogViewer.mousepressed(x, y, button)
    lastInput = "mouse"
    if not isVisible then return false end
    
    -- Transform coordinates to account for scaling and offset
    local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
    
    -- Check if mouse is over scrollbar
    local scrollbar = dialog.scrollbar
    if scrollbar.isHovered and button == 1 then
        scrollbar.isDragging = true
        
        -- Calculate drag offset from top of thumb
        local trackHeight = dialog.height - padding * 2
        local thumbHeight = math.max(40, (maxVisibleLines / totalLines) * trackHeight)
        local thumbY = dialog.y + padding + (scrollPosition / (totalLines - maxVisibleLines)) * (trackHeight - thumbHeight)
        scrollbar.dragOffsetY = transformedY - thumbY
        
        return true
    end
    
    -- Close button click
    if button == 1 and transformedX >= closeButton.x and transformedX <= closeButton.x + closeButton.width and
       transformedY >= closeButton.y and transformedY <= closeButton.y + closeButton.height then
        gameLogViewer.hide()
        return true
    end

    -- Click outside the close button: in mouse mode, clear focus
    if lastInput == "mouse" and button == 1 then
        if closeButton.focused then
            closeButton.focused = false
        end
        return false
    end

    return false
end

function gameLogViewer.update(dt)
    if not isVisible then return end
    if scrollbarFlashTimer and scrollbarFlashTimer > 0 then
        scrollbarFlashTimer = math.max(0, scrollbarFlashTimer - dt)
    end

    -- Handle press-and-hold auto scrolling
    if holdDir ~= 0 and totalLines > maxVisibleLines then
        -- While holding, keep the button defocused and postpone refocus
        closeButton.focused = false
        refocusTimer = REFOCUS_DELAY
        holdTimer = holdTimer - dt
        if holdTimer <= 0 then
            -- perform one scroll step in hold direction
            local before = scrollPosition
            if holdDir < 0 then
                scrollPosition = clampScroll(scrollPosition - 1)
            else
                scrollPosition = clampScroll(scrollPosition + 1)
            end
            holdTimer = holdRepeatInterval
            if scrollPosition ~= before then
                scrollbarFlashTimer = 0.2
                playScrollSound()
            end
        end
    end
    -- Refocus timer countdown for mouse wheel; when expires, refocus button (if no dragging)
    if refocusTimer and refocusTimer > 0 then
        refocusTimer = math.max(0, refocusTimer - dt)
        if refocusTimer == 0 and not dialog.scrollbar.isDragging then
            -- Only auto-refocus after delay if last input was keyboard
            if lastInput == "keyboard" and not closeButton.focused then
                closeButton.focused = true
                playButtonFocusSound()
            end
        end
    end
end

function gameLogViewer.mousereleased(x, y, button)
    lastInput = "mouse"
    if not isVisible then return false end
    
    -- Reset scrollbar dragging
    if dialog.scrollbar.isDragging then
        dialog.scrollbar.isDragging = false
        -- After mouse drag ends, do NOT auto focus in mouse mode; wait for hover
        refocusTimer = 0
        return true
    end
    
    return false
end

function gameLogViewer.wheelmoved(x, y)
    lastInput = "mouse"
    if not isVisible then return false end
    
    -- Scroll up/down with mouse wheel
    local before = scrollPosition
    local before = scrollPosition
    local target = scrollPosition - y * 3
    scrollPosition = clampScroll(target)
    if scrollPosition ~= before then
        scrollbarFlashTimer = 0.2
        -- Defocus button during mouse scrolling, then refocus after short delay
        closeButton.focused = false
        refocusTimer = REFOCUS_DELAY
        playScrollSound()
    end
    
    return true
end

function gameLogViewer.keypressed(key)
    lastInput = "keyboard"
    if not isVisible then return false end
    
    if key == "up" or key == "w" then
        local before = scrollPosition
        scrollPosition = clampScroll(scrollPosition - 1)
        -- Immediately defocus the Close button when starting to scroll via keyboard
        closeButton.focused = false
        refocusTimer = REFOCUS_DELAY
        if scrollPosition ~= before then
            scrollbarFlashTimer = 0.2
            playScrollSound()
        end
        -- start hold in up direction
        holdDir = -1
        holdTimer = holdInitialDelay
        return true
    elseif key == "down" or key == "s" then
        local before = scrollPosition
        scrollPosition = clampScroll(scrollPosition + 1)
        -- Immediately defocus the Close button when starting to scroll via keyboard
        closeButton.focused = false
        refocusTimer = REFOCUS_DELAY
        if scrollPosition ~= before then
            scrollbarFlashTimer = 0.2
            playScrollSound()
        end
        -- start hold in down direction
        holdDir = 1
        holdTimer = holdInitialDelay
        return true
    elseif key == "pageup" then
        local before = scrollPosition
        scrollPosition = clampScroll(scrollPosition - maxVisibleLines)
        -- Defocus even if no movement (at top)
        closeButton.focused = false
        refocusTimer = REFOCUS_DELAY
        if scrollPosition ~= before then
            scrollbarFlashTimer = 0.2
            playScrollSound()
        end
        return true
    elseif key == "pagedown" then
        local before = scrollPosition
        scrollPosition = clampScroll(scrollPosition + maxVisibleLines)
        -- Defocus even if no movement (at bottom)
        closeButton.focused = false
        refocusTimer = REFOCUS_DELAY
        if scrollPosition ~= before then
            scrollbarFlashTimer = 0.2
            playScrollSound()
        end
        return true
    elseif key == "home" then
        scrollPosition = clampScroll(0)
        return true
    elseif (key == "return" or key == "space") and closeButton.focused then
        gameLogViewer.hide()
        return true
    elseif key == "escape" then
        gameLogViewer.hide()
        return true
    end
    
    return false
end

function gameLogViewer.keyreleased(key)
    if not isVisible then return false end
    if ((key == "up" or key == "w") and holdDir < 0) or ((key == "down" or key == "s") and holdDir > 0) then
        holdDir = 0
        holdTimer = 0
        -- Refocus close button when scrolling via keyboard stops (keyboard mode only)
        if lastInput == "keyboard" and not closeButton.focused then
            closeButton.focused = true
            playButtonFocusSound()
        end
        refocusTimer = 0
        return true
    end
    return false
end

return gameLogViewer
