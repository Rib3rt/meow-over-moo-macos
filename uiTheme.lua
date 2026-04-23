local uiTheme = {}

uiTheme.COLORS = {
    background = {46/255, 38/255, 32/255, 0.9},
    border = {108/255, 88/255, 66/255, 1},
    text = {203/255, 183/255, 158/255, 0.95},
    highlight = {79/255, 62/255, 46/255, 0.9},
    button = {46/255, 38/255, 32/255, 0.9},
    buttonHover = {68/255, 60/255, 54/255, 0.92},
    buttonPressed = {34/255, 29/255, 24/255, 0.9},
    blueTeam = {0.2, 0.4, 0.8, 1},
    redTeam = {0.8, 0.2, 0.2, 1},
    titleGlow = {1, 0.8, 0.2, 0.7},
    arrowSelected = {1, 0.9, 0.2, 1},
    arrowGlow = {1, 0.9, 0.2, 0.5}
}

uiTheme.TYPOGRAPHY = {
    title = 28,
    body = 18,
    button = 18,
    small = 14
}

uiTheme.SPACING = {
    xs = 4,
    sm = 8,
    md = 12,
    lg = 16,
    xl = 24
}

uiTheme.PANEL = {
    cornerRadius = 8,
    borderWidth = 2,
    innerBorderInset = 3,
    innerCornerRadius = 6
}

uiTheme.BUTTON_VARIANTS = {
    default = {
        base = {46/255, 38/255, 32/255, 0.9},
        hover = {68/255, 60/255, 54/255, 0.92},
        pressed = {34/255, 29/255, 24/255, 0.9},
        border = {108/255, 88/255, 66/255, 1},
        text = {203/255, 183/255, 158/255, 0.95}
    },
    success = {
        base = {48/255, 134/255, 72/255, 0.95},
        hover = {63/255, 158/255, 88/255, 0.98},
        pressed = {38/255, 112/255, 60/255, 0.98},
        border = {0.25, 0.55, 0.33, 0.98},
        text = {0.92, 0.99, 0.93, 1}
    },
    danger = {
        base = {115/255, 49/255, 49/255, 0.95},
        hover = {138/255, 60/255, 60/255, 0.98},
        pressed = {90/255, 39/255, 39/255, 0.98},
        border = {0.58, 0.25, 0.25, 1},
        text = {0.98, 0.92, 0.92, 1}
    },
    disabled = {
        base = {18/255, 16/255, 14/255, 0.98},
        hover = {18/255, 16/255, 14/255, 0.98},
        pressed = {18/255, 16/255, 14/255, 0.98},
        border = {0.14, 0.13, 0.12, 1},
        text = {0.38, 0.35, 0.31, 0.92}
    }
}

local function copyColor(color)
    return {color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1}
end

function uiTheme.lighten(color, factor)
    local r, g, b = color[1] or 1, color[2] or 1, color[3] or 1
    local a = color[4] or 1
    return {
        r + (1 - r) * factor,
        g + (1 - g) * factor,
        b + (1 - b) * factor,
        a
    }
end

function uiTheme.darken(color, factor)
    local r, g, b = color[1] or 1, color[2] or 1, color[3] or 1
    local a = color[4] or 1
    return {
        r * (1 - factor),
        g * (1 - factor),
        b * (1 - factor),
        a
    }
end

function uiTheme.desaturate(color, amount)
    local r, g, b = color[1] or 1, color[2] or 1, color[3] or 1
    local a = color[4] or 1
    local gray = r * 0.299 + g * 0.587 + b * 0.114
    return {
        r + (gray - r) * amount,
        g + (gray - g) * amount,
        b + (gray - b) * amount,
        a
    }
end

function uiTheme.drawTechPanel(x, y, width, height)
    local colors = uiTheme.COLORS
    local panel = uiTheme.PANEL
    love.graphics.setColor(colors.background)
    love.graphics.rectangle("fill", x, y, width, height, panel.cornerRadius)

    love.graphics.setColor(colors.border)
    love.graphics.setLineWidth(panel.borderWidth)
    love.graphics.rectangle("line", x, y, width, height, panel.cornerRadius)
    love.graphics.setLineWidth(1)

    love.graphics.setColor(colors.highlight)
    love.graphics.rectangle(
        "line",
        x + panel.innerBorderInset,
        y + panel.innerBorderInset,
        width - (panel.innerBorderInset * 2),
        height - (panel.innerBorderInset * 2),
        panel.innerCornerRadius
    )
end

function uiTheme.drawTitle(text, x, y, width)
    local safeText = (type(text) == "string") and text or ""
    local colors = uiTheme.COLORS
    local time = love.timer.getTime()
    local pulseAlpha = 0.5 + 0.5 * math.sin(time * 2)

    love.graphics.setColor(colors.text)
    love.graphics.printf(safeText, x, y, width, "center")

    local font = love.graphics.getFont()
    local textWidth = font:getWidth(safeText) * 1.5
    local lineY = y + font:getHeight() + 10

    love.graphics.setColor(colors.titleGlow[1], colors.titleGlow[2], colors.titleGlow[3], pulseAlpha * (colors.titleGlow[4] or 1))
    love.graphics.line(x + (width - textWidth) / 2, lineY, x + (width + textWidth) / 2, lineY)
end

local function transformButtonText(text, button)
    local safeText = (type(text) == "string") and text or ""
    if type(button) ~= "table" then
        return safeText
    end

    if button.textTransform == "uppercase" then
        return string.upper(safeText)
    end
    if button.textTransform == "lowercase" then
        return string.lower(safeText)
    end
    return safeText
end

local function drawCenteredTrackedText(text, x, y, width, letterSpacing)
    local safeText = (type(text) == "string") and text or ""
    local len = #safeText
    if len == 0 then
        return
    end

    local font = love.graphics.getFont()
    local spacing = tonumber(letterSpacing) or 0
    if spacing <= 0 or len == 1 then
        love.graphics.printf(safeText, x, y, width, "center")
        return
    end

    local totalWidth = 0
    for i = 1, len do
        totalWidth = totalWidth + font:getWidth(safeText:sub(i, i))
        if i < len then
            totalWidth = totalWidth + spacing
        end
    end

    local cursorX = x + ((width - totalWidth) * 0.5)
    for i = 1, len do
        local ch = safeText:sub(i, i)
        love.graphics.print(ch, cursorX, y)
        cursorX = cursorX + font:getWidth(ch) + spacing
    end
end

function uiTheme.drawButton(button)
    if not button then return end

    local colors = uiTheme.COLORS
    local panel = uiTheme.PANEL
    local currentColor = button.currentColor or colors.button

    love.graphics.setColor(currentColor)
    love.graphics.rectangle("fill", button.x, button.y, button.width, button.height, panel.cornerRadius)

    local isDisabled = button.disabledVisual == true
    local isHovered = (button.hoverColor and button.currentColor == button.hoverColor) and not isDisabled
    local isFocused = (button.focused == true) and not isDisabled

    if isHovered or isFocused then
        love.graphics.setColor(255 / 255, 240 / 255, 220 / 255, 0.8)
        love.graphics.setLineWidth(2.5)
    else
        local border = button.borderColor or colors.border
        love.graphics.setColor(border)
        love.graphics.setLineWidth(2)
    end
    love.graphics.rectangle("line", button.x, button.y, button.width, button.height, panel.cornerRadius)
    love.graphics.setLineWidth(1)

    local innerAlpha = isDisabled and 0.06 or 0.2
    love.graphics.setColor(1, 1, 1, innerAlpha)
    love.graphics.rectangle(
        "line",
        button.x + panel.innerBorderInset,
        button.y + panel.innerBorderInset,
        button.width - (panel.innerBorderInset * 2),
        button.height - (panel.innerBorderInset * 2),
        panel.innerCornerRadius
    )

    love.graphics.setColor(button.textColor or colors.text)
    local text = transformButtonText(button.text or "", button)
    local textOffsetY = button.textOffsetY
    if textOffsetY == nil and button.centerText == true then
        textOffsetY = (button.height - love.graphics.getFont():getHeight()) / 2
    end
    textOffsetY = textOffsetY or 15
    drawCenteredTrackedText(text, button.x, button.y + textOffsetY, button.width, button.letterSpacing)
end

function uiTheme.applyButtonVariant(button, variantName)
    if type(button) ~= "table" then
        return button
    end
    local variant = uiTheme.BUTTON_VARIANTS[variantName] or uiTheme.BUTTON_VARIANTS.default
    button.baseColor = variant.base
    button.hoverColor = variant.hover
    button.pressedColor = variant.pressed
    button.borderColor = variant.border
    button.textColor = variant.text
    if button.currentColor == nil then
        button.currentColor = button.baseColor
    end
    return button
end

function uiTheme.getFactionColor(factionIndex)
    if factionIndex == 1 then
        return copyColor(uiTheme.COLORS.blueTeam)
    elseif factionIndex == 2 then
        return copyColor(uiTheme.COLORS.redTeam)
    end
    return copyColor(uiTheme.COLORS.text)
end

return uiTheme
