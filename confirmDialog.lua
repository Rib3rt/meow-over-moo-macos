local confirmDialog = {}

--------------------------------------------------
-- LOCAL VARIABLES
--------------------------------------------------
local isVisible = false
local message = ""
local dialogTitle = "Confirm"
local onConfirm = nil
local onCancel = nil
local focusedButton = "cancel" -- Track which button is currently focused ("confirm" or "cancel")
local clickProcessed = false -- New flag to track if a click has been processed
local activeButton = nil -- Track which button was initially pressed
local singleButtonMode = false

-- Audio sources for consistent UI sounds
local soundCache = require("soundCache")
local steamRuntime = require("steam_runtime")
local uiTheme = require("uiTheme")

local buttonBeepSound = nil
local buttonClickSound = nil
local BUTTON_BEEP_SOUND_PATH = "assets/audio/GenericButton14.wav"
local BUTTON_CLICK_SOUND_PATH = "assets/audio/GenericButton6.wav"
local DIALOG_APPEAR_SOUND_PATH = "assets/audio/Popup2.wav"

-- UI colors matching the game's style
local UI_COLORS = uiTheme.COLORS

-- Dialog dimensions and position
local dialog = {
    width = 400,
    height = 180,
    minWidth = 360,
    maxWidth = 560,
    minHeight = 180,
    maxHeight = 360,
    wrappedMessage = {},
    buttons = {
        confirm = {
            width = 150,
            height = 40,
            text = "Yes",
            currentColor = UI_COLORS.button,
            hoverColor = UI_COLORS.buttonHover,
            pressedColor = UI_COLORS.buttonPressed
        },
        cancel = {
            width = 150,
            height = 40,
            text = "No",
            currentColor = UI_COLORS.button,
            hoverColor = UI_COLORS.buttonHover,
            pressedColor = UI_COLORS.buttonPressed
        }
    }
}

--------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------
local function isMouseOverButton(button, x, y)
    return (x >= button.x and x <= button.x + button.width) and
           (y >= button.y and y <= button.y + button.height)
end

-- Draw a tech-styled panel
local function drawTechPanel(x, y, width, height)
    uiTheme.drawTechPanel(x, y, width, height)
end

local function drawButton(button)
    uiTheme.drawButton(button)
end

local function resetTransientInputs(reason)
    if GAME and GAME.CURRENT and GAME.CURRENT.STATE_MACHINE and GAME.CURRENT.STATE_MACHINE.resetTransientInputs then
        GAME.CURRENT.STATE_MACHINE.resetTransientInputs(reason or "confirm_dialog")
    end
end

local function getWrappedMessageLines(textValue, maxWidth)
    local safeText = tostring(textValue or "")
    local width = math.max(120, math.floor(tonumber(maxWidth) or 120))
    local font = love.graphics.getFont()
    local _, wrapped = font:getWrap(safeText, width)
    if type(wrapped) ~= "table" or #wrapped == 0 then
        wrapped = {safeText}
    end
    return wrapped
end

local function recomputeDialogHeight()
    local topPadding = 20
    local titleToMessageGap = 14
    local messageToButtonsGap = 18
    local bottomPadding = 20
    local messageWidth = dialog.width - 40

    local font = love.graphics.getFont()
    local lineHeight = font:getHeight()
    dialog.wrappedMessage = getWrappedMessageLines(message, messageWidth)

    local messageHeight = math.max(lineHeight, (#dialog.wrappedMessage * lineHeight))
    local desiredHeight = topPadding + lineHeight + titleToMessageGap + messageHeight + messageToButtonsGap + dialog.buttons.confirm.height + bottomPadding
    dialog.height = math.max(dialog.minHeight, math.min(dialog.maxHeight, math.ceil(desiredHeight)))
end

--------------------------------------------------
-- PUBLIC FUNCTIONS
--------------------------------------------------

-- Audio sources for consistent UI sounds
local dialogAppearSound = nil

-- Initialize audio sources
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
    if not dialogAppearSound then
        dialogAppearSound = soundCache.get(DIALOG_APPEAR_SOUND_PATH)
        if dialogAppearSound then
            dialogAppearSound:setVolume(SETTINGS.AUDIO.SFX_VOLUME)
        end
    end
end

local function playDialogHoverSound()
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

local function playDialogClickSound()
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

local function playDialogAppearSound()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(DIALOG_APPEAR_SOUND_PATH, {
        clone = false,
        volume = SETTINGS.AUDIO.SFX_VOLUME,
        category = "sfx"
    })
end

-- Show the confirmation dialog with a message and callback functions
function confirmDialog.show(messageText, confirmCallback, cancelCallback, options)
    initAudio() -- Initialize audio when showing dialog

    options = options or {}
    singleButtonMode = options.singleButton == true

    local confirmText = tostring(options.confirmText or "Yes")
    local cancelText = tostring(options.cancelText or "No")
    local defaultFocus = (options.defaultFocus == "confirm") and "confirm" or "cancel"
    local requestedWidth = tonumber(options.width)
    if singleButtonMode then
        defaultFocus = "confirm"
    end

    isVisible = true
    message = tostring(options.message or messageText or "Are you sure?")
    dialogTitle = tostring(options.title or "Confirm")
    onConfirm = confirmCallback
    onCancel = cancelCallback
    focusedButton = defaultFocus
    clickProcessed = false -- Reset click processed flag when showing new dialog
    activeButton = nil -- Reset active button when showing new dialog

    dialog.buttons.confirm.text = confirmText
    dialog.buttons.cancel.text = cancelText
    uiTheme.applyButtonVariant(dialog.buttons.confirm, "default")
    uiTheme.applyButtonVariant(dialog.buttons.cancel, "default")
    dialog.buttons.confirm.textOffsetY = dialog.buttons.confirm.textOffsetY or (dialog.buttons.confirm.height / 2 - 10)
    dialog.buttons.cancel.textOffsetY = dialog.buttons.cancel.textOffsetY or (dialog.buttons.cancel.height / 2 - 10)
    if requestedWidth and requestedWidth > 0 then
        dialog.width = math.floor(requestedWidth)
    else
        dialog.width = 400
    end
    dialog.width = math.max(dialog.minWidth, math.min(dialog.maxWidth, dialog.width))
    recomputeDialogHeight()
    if #dialog.wrappedMessage > 6 and dialog.width < dialog.maxWidth then
        dialog.width = math.min(dialog.maxWidth, dialog.width + 120)
        recomputeDialogHeight()
    end

    if focusedButton == "confirm" then
        dialog.buttons.confirm.currentColor = UI_COLORS.buttonHover
        dialog.buttons.confirm.focused = true
        dialog.buttons.cancel.currentColor = UI_COLORS.button
        dialog.buttons.cancel.focused = false
    else
        dialog.buttons.confirm.currentColor = UI_COLORS.button
        dialog.buttons.confirm.focused = false
        dialog.buttons.cancel.currentColor = UI_COLORS.buttonHover
        dialog.buttons.cancel.focused = true
    end

    local transformedWidth = SETTINGS.DISPLAY.WIDTH / SETTINGS.DISPLAY.SCALE
    local transformedHeight = SETTINGS.DISPLAY.HEIGHT / SETTINGS.DISPLAY.SCALE

    dialog.x = (transformedWidth - dialog.width) / 2
    dialog.y = (transformedHeight - dialog.height) / 2

    if singleButtonMode then
        dialog.buttons.confirm.x = dialog.x + (dialog.width - dialog.buttons.confirm.width) / 2
        dialog.buttons.confirm.y = dialog.y + dialog.height - dialog.buttons.confirm.height - 20
        dialog.buttons.cancel.x = dialog.buttons.confirm.x
        dialog.buttons.cancel.y = dialog.buttons.confirm.y
    else
        dialog.buttons.confirm.x = dialog.x + dialog.width/2 - dialog.buttons.confirm.width - 10
        dialog.buttons.confirm.y = dialog.y + dialog.height - dialog.buttons.confirm.height - 20

        dialog.buttons.cancel.x = dialog.x + dialog.width/2 + 10
        dialog.buttons.cancel.y = dialog.y + dialog.height - dialog.buttons.cancel.height - 20
    end

    local focusButton = dialog.buttons.confirm
    if not singleButtonMode and focusedButton == "cancel" then
        focusButton = dialog.buttons.cancel
    end
    local focusCenterX = focusButton.x + focusButton.width/2
    local focusCenterY = focusButton.y + focusButton.height/2

    local screenX = focusCenterX * SETTINGS.DISPLAY.SCALE + SETTINGS.DISPLAY.OFFSETX
    local screenY = focusCenterY * SETTINGS.DISPLAY.SCALE + SETTINGS.DISPLAY.OFFSETY

    love.mouse.setPosition(screenX, screenY)

    resetTransientInputs("confirm_dialog_show")
    playDialogAppearSound()
end

function confirmDialog.showMessage(messageText, acknowledgeCallback, options)
    options = options or {}
    options.singleButton = true
    options.confirmText = tostring(options.confirmText or "OK")
    options.defaultFocus = "confirm"
    return confirmDialog.show(messageText, acknowledgeCallback, acknowledgeCallback, options)
end

-- Hide the confirmation dialog
function confirmDialog.hide(confirmed)
    if not isVisible then return end -- Already hidden, do nothing
    
    isVisible = false
    resetTransientInputs("confirm_dialog_hide")
    if confirmed and onConfirm then
        onConfirm()
    elseif not confirmed and onCancel then
        onCancel()
    end
end

-- Check if dialog is currently visible
function confirmDialog.isActive()
    return isVisible
end

function confirmDialog.draw()
    if not isVisible then return end
    
    -- We don't need to push/translate/scale here because it's already done in mainMenu.draw()
    
    -- Get actual screen dimensions
    local actualWidth, actualHeight = love.graphics.getDimensions()
    
    -- Darkened overlay (covers entire screen)
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)
    
    -- Use dialog's fixed dimensions
    local dialogWidth = dialog.width 
    recomputeDialogHeight()
    local dialogHeight = dialog.height
    local buttonWidth = dialog.buttons.confirm.width
    local buttonHeight = dialog.buttons.confirm.height
    local topPadding = 20
    local titleToMessageGap = 14
    local messageToButtonsGap = 18
    
    -- Center dialog based on actual transformed screen dimensions
    local transformedWidth = actualWidth / SETTINGS.DISPLAY.SCALE
    local transformedHeight = actualHeight / SETTINGS.DISPLAY.SCALE
    
    -- Account for the offset in our calculations
    transformedWidth = transformedWidth - (SETTINGS.DISPLAY.OFFSETX * 2 / SETTINGS.DISPLAY.SCALE)
    transformedHeight = transformedHeight - (SETTINGS.DISPLAY.OFFSETY * 2 / SETTINGS.DISPLAY.SCALE)
    
    -- Position dialog and buttons
    dialog.x = (transformedWidth - dialogWidth) / 2
    dialog.y = (transformedHeight - dialogHeight) / 2
    
    if singleButtonMode then
        dialog.buttons.confirm.x = dialog.x + (dialogWidth - buttonWidth) / 2
        dialog.buttons.confirm.y = dialog.y + dialogHeight - buttonHeight - 20
        dialog.buttons.cancel.x = dialog.buttons.confirm.x
        dialog.buttons.cancel.y = dialog.buttons.confirm.y
    else
        dialog.buttons.confirm.x = dialog.x + dialogWidth/2 - buttonWidth - 10
        dialog.buttons.confirm.y = dialog.y + dialogHeight - buttonHeight - 20

        dialog.buttons.cancel.x = dialog.x + dialogWidth/2 + 10
        dialog.buttons.cancel.y = dialog.y + dialogHeight - buttonHeight - 20
    end
    
    -- Draw dialog panel with fixed dimensions
    drawTechPanel(dialog.x, dialog.y, dialogWidth, dialogHeight)

    -- Draw title and message
    love.graphics.setColor(UI_COLORS.text)
    local titleY = dialog.y + topPadding
    love.graphics.printf(dialogTitle or "Confirm", dialog.x, titleY, dialogWidth, "center")
    
    love.graphics.setColor(UI_COLORS.text)
    local messageY = titleY + love.graphics.getFont():getHeight() + titleToMessageGap
    local maxMessageHeight = dialog.buttons.confirm.y - messageToButtonsGap - messageY
    if maxMessageHeight < love.graphics.getFont():getHeight() then
        maxMessageHeight = love.graphics.getFont():getHeight()
    end
    love.graphics.setScissor(
        math.floor((dialog.x + 20) * SETTINGS.DISPLAY.SCALE + SETTINGS.DISPLAY.OFFSETX),
        math.floor(messageY * SETTINGS.DISPLAY.SCALE + SETTINGS.DISPLAY.OFFSETY),
        math.floor((dialogWidth - 40) * SETTINGS.DISPLAY.SCALE),
        math.floor(maxMessageHeight * SETTINGS.DISPLAY.SCALE)
    )
    love.graphics.printf(message, dialog.x + 20, messageY, dialogWidth - 40, "center")
    love.graphics.setScissor()
    
    -- Draw buttons
    drawButton(dialog.buttons.confirm)
    if not singleButtonMode then
        drawButton(dialog.buttons.cancel)
    end
end

-- Handle mouse movement for button hover effects
function confirmDialog.mousemoved(x, y)
    if not isVisible then return end

    if singleButtonMode then
        local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
        local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
        local hovered = isMouseOverButton(dialog.buttons.confirm, transformedX, transformedY)
        dialog.buttons.confirm.currentColor = hovered and dialog.buttons.confirm.hoverColor or UI_COLORS.buttonHover
        dialog.buttons.confirm.focused = true
        dialog.buttons.cancel.focused = false
        focusedButton = "confirm"
        return
    end
    
    -- Transform coordinates to account for scaling and offset
    local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
    
    -- Reset button colors first to default state
    dialog.buttons.confirm.currentColor = UI_COLORS.button
    dialog.buttons.cancel.currentColor = UI_COLORS.button
    
    -- Check if mouse is over any button using transformed coordinates
    local isOverConfirm = isMouseOverButton(dialog.buttons.confirm, transformedX, transformedY)
    local isOverCancel = isMouseOverButton(dialog.buttons.cancel, transformedX, transformedY)
    
    -- Update focus based on mouse position and play navigation sound
    local previousFocus = focusedButton
    if isOverConfirm then
        focusedButton = "confirm"
        dialog.buttons.confirm.currentColor = dialog.buttons.confirm.hoverColor
        dialog.buttons.confirm.focused = true
        dialog.buttons.cancel.focused = false
    elseif isOverCancel then
        focusedButton = "cancel"
        dialog.buttons.cancel.currentColor = dialog.buttons.cancel.hoverColor
        dialog.buttons.cancel.focused = true
        dialog.buttons.confirm.focused = false
    end
    
    -- Play navigation sound if focus changed
    if previousFocus ~= focusedButton then
        playDialogHoverSound()
    end
    
    -- If mouse isn't over any button, keep the currently focused button highlighted
    if not (isOverConfirm or isOverCancel) then
        if focusedButton == "confirm" then
            dialog.buttons.confirm.currentColor = dialog.buttons.confirm.hoverColor
            dialog.buttons.confirm.focused = true
            dialog.buttons.cancel.focused = false
        else -- "cancel" is the default
            dialog.buttons.cancel.currentColor = dialog.buttons.cancel.hoverColor
            dialog.buttons.cancel.focused = true
            dialog.buttons.confirm.focused = false
        end
    end
end

-- Handle mouse clicks
function confirmDialog.mousepressed(x, y, button)
    if not isVisible or button ~= 1 then return false end

    if singleButtonMode then
        local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
        local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
        if isMouseOverButton(dialog.buttons.confirm, transformedX, transformedY) then
            activeButton = "confirm"
            dialog.buttons.confirm.currentColor = dialog.buttons.confirm.pressedColor
            playDialogClickSound()
            return true
        end
        activeButton = nil
        return true
    end
    
    -- Transform coordinates to account for scaling and offset
    local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
    
    -- Track which button was initially pressed using transformed coordinates
    if isMouseOverButton(dialog.buttons.confirm, transformedX, transformedY) then
        activeButton = "confirm"
        dialog.buttons.confirm.currentColor = dialog.buttons.confirm.pressedColor
        clickProcessed = false
        -- Play click sound
        playDialogClickSound()
        return true
    end
    
    if isMouseOverButton(dialog.buttons.cancel, transformedX, transformedY) then
        activeButton = "cancel"
        dialog.buttons.cancel.currentColor = dialog.buttons.cancel.pressedColor
        clickProcessed = false
        -- Play click sound
        playDialogClickSound()
        return true
    end
    
    -- If clicked outside buttons, don't track anything
    activeButton = nil
    return true
end

-- Handle mouse button releases - this is when the actual action happens
function confirmDialog.mousereleased(x, y, button)
    if not isVisible or button ~= 1 then return false end

    if singleButtonMode then
        local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
        local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
        if activeButton == "confirm" and isMouseOverButton(dialog.buttons.confirm, transformedX, transformedY) then
            dialog.buttons.confirm.currentColor = dialog.buttons.confirm.hoverColor
            confirmDialog.hide(true)
            activeButton = nil
            return true
        end
        if activeButton == "confirm" then
            dialog.buttons.confirm.currentColor = dialog.buttons.confirm.hoverColor
        end
        activeButton = nil
        return true
    end
    
    -- Transform coordinates to account for scaling and offset
    local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
    
    -- Only process if we have an active button that was initially pressed
    if activeButton then
        -- Check if mouse is still over the SAME button that was initially pressed using transformed coordinates
        if activeButton == "confirm" and isMouseOverButton(dialog.buttons.confirm, transformedX, transformedY) then
            -- Reset button color
            dialog.buttons.confirm.currentColor = dialog.buttons.confirm.hoverColor
            
            -- Execute callback and hide dialog
            confirmDialog.hide(true)
            activeButton = nil
            return true
        end
        
        if activeButton == "cancel" and isMouseOverButton(dialog.buttons.cancel, transformedX, transformedY) then
            -- Reset button color
            dialog.buttons.cancel.currentColor = dialog.buttons.cancel.hoverColor
            
            -- Execute callback and hide dialog
            confirmDialog.hide(false)
            activeButton = nil
            return true
        end
    
        -- If mouse is released elsewhere, just reset button appearance
        if activeButton == "confirm" then
            dialog.buttons.confirm.currentColor = dialog.buttons.confirm.hoverColor
        else
            dialog.buttons.cancel.currentColor = dialog.buttons.cancel.hoverColor
        end
        
        activeButton = nil
    end
    
    -- If the click was outside any button, don't close the dialog
    return true
end

function confirmDialog.keypressed(key)
    if not confirmDialog.isActive() then
        return false
    end

    if singleButtonMode then
        if key == "return" or key == "space" or key == "escape" then
            playDialogClickSound()
            local confirmCallback = onConfirm
            isVisible = false
            if confirmCallback then
                confirmCallback()
            end
            return true
        end
        return false
    end
    
    if key == "return" or key == "space" then
        -- Play click sound
        playDialogClickSound()
        
        -- Store callbacks locally before hiding dialog
        local confirmCallback = onConfirm
        local cancelCallback = onCancel
        
        -- Set dialog to hidden first
        isVisible = false
        
        -- Execute the callback after hiding dialog
        if focusedButton == "confirm" then
            if confirmCallback then
                confirmCallback()
            end
        else
            if cancelCallback then
                cancelCallback()
            end
        end
        
        return true
    elseif key == "escape" then
        -- Store callback locally before hiding dialog
        local cancelCallback = onCancel
        
        -- Set dialog to hidden first
        isVisible = false
        
        -- Execute callback after hiding dialog
        if cancelCallback then
            cancelCallback()
        end
        return true
    elseif key == "left" or key == "a" or key == "right" or key == "d" or key == "up" or key == "down" or key == "w" or key == "s" then
        -- Toggle focused button between confirm and cancel
        if focusedButton == "confirm" then
            focusedButton = "cancel"
            dialog.buttons.confirm.currentColor = UI_COLORS.button
            dialog.buttons.confirm.focused = false
            dialog.buttons.cancel.currentColor = UI_COLORS.buttonHover
            dialog.buttons.cancel.focused = true
        else
            focusedButton = "confirm"
            dialog.buttons.cancel.currentColor = UI_COLORS.button
            dialog.buttons.cancel.focused = false
            dialog.buttons.confirm.currentColor = UI_COLORS.buttonHover
            dialog.buttons.confirm.focused = true
        end
        
        -- Play navigation sound
        playDialogHoverSound()
        return true
    end

    return false
end

function confirmDialog.gamepadpressed(joystick, button)
    if not isVisible then
        return false
    end

    if button == "a" then
        return confirmDialog.keypressed("return")
    elseif button == "b" or button == "back" then
        return confirmDialog.keypressed("escape")
    elseif button == "guide" then
        -- Reserved mapping: on Steam builds, open overlay if available.
        steamRuntime.onGuideButtonPressed()
        return true
    elseif button == "dpup" or button == "dpleft" then
        return confirmDialog.keypressed("left")
    elseif button == "dpdown" or button == "dpright" then
        return confirmDialog.keypressed("right")
    elseif button == "leftshoulder" then
        return confirmDialog.keypressed("left")
    elseif button == "rightshoulder" then
        return confirmDialog.keypressed("right")
    end

    return false
end

function confirmDialog.update(dt)

end

return confirmDialog
