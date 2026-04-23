local unitsInfo = require("unitsInfo")
local ConfirmDialog = require("confirmDialog")
local GameLogViewer = require("gameLogViewer")
local randomGen = require("randomGenerator")
local uiTheme = require("uiTheme")
local fontCache = require("fontCache")
local soundCache = require("soundCache")
local Factions = require("factions")
local MONOGRAM_FONT_PATH = "assets/fonts/monogram-extended.ttf"

local function getMonogramFont(size)
    return fontCache.get(MONOGRAM_FONT_PATH, size)
end

local function getDefaultFont(size)
    return fontCache.getDefault(size)
end

local function cloneColor(color)
    if type(color) ~= "table" then
        return {1, 1, 1, 1}
    end
    return {
        color[1] or 1,
        color[2] or 1,
        color[3] or 1,
        color[4] or 1
    }
end

local ONLINE_REACTION_DEFINITIONS = {
    {
        id = "good",
        label = "GOOD",
        message = "Well played!",
        variant = "default"
    },
    {
        id = "zzz",
        label = "ZZZ",
        message = "Boring...",
        variant = "default"
    },
    {
        id = "bad",
        label = "BAD",
        message = "Not fun!",
        variant = "default"
    }
}

local ONLINE_REACTION_NOTIFICATION_DURATION = 3.0
local uiClass = {}
uiClass.__index = uiClass

function uiClass.new(params)
    params = params or {}
    local self = setmetatable({}, uiClass)

    self.unitsInfo = unitsInfo
    self.hideSupplyPanels = params.hideSupplyPanels == true
    self.suppressGameOverPanel = params.suppressGameOverPanel == true
    self.gameRuler = params.gameRuler or nil
    self.stateMachineRef = params.stateMachine or nil
    self.onSurrenderRequested = params.onSurrenderRequested
    self.onOnlineReactionRequested = params.onOnlineReactionRequested
    self.onScenarioBackRequested = params.onScenarioBackRequested
    self.onScenarioRetryRequested = params.onScenarioRetryRequested
    self.onlineReactionButtons = {
        cooldownUntil = 0,
        buttons = {},
        lastHoverName = nil
    }
    self.onlineReactionNotification = {
        visible = false,
        startedAt = 0,
        duration = ONLINE_REACTION_NOTIFICATION_DURATION,
        reactionId = nil,
        senderFaction = nil,
        senderName = nil,
        message = nil
    }
    
    -- Initialize UI sound sources via sound cache for consistent reuse
    self.buttonBeepSoundPath = "assets/audio/GenericButton6.wav"
    self.supplyBeepSoundPath = "assets/audio/GenericButton14.wav"
    self.victoryYaySoundPath = "assets/audio/VictoryYay.ogg"

    -- Prime sounds in the cache (non-fatal if missing)
    soundCache.get(self.buttonBeepSoundPath)
    soundCache.get(self.supplyBeepSoundPath)
    soundCache.get(self.victoryYaySoundPath)

    -- Basic UI parameters
    self.panelWidth = params.panelWidth or 220
    self.panelHeight = params.panelHeight or 340

    -- Unit selection tracking
    self.selectedUnit = nil
    self.hooverdUnit = nil
    self.hoveredUnitPlayer = nil
    self.hoveredUnitIndex = nil
    self.selectedUnitPlayer = nil
    self.selectedUnitOwner = nil
    self.selectedUnitIndex = nil
    self.selectedUnitCoordOnPanel = nil
    self.unitPositions = {}

    -- Supply arrays
    self.playerSupply1 = {}
    self.playerSupply2 = {}
    self.playerSupply1Faction = 1
    self.playerSupply2Faction = 2
    self.playerSupply1Owner = 1
    self.playerSupply2Owner = 2
    self.playerSupplyControllers = {
        [1] = nil,
        [2] = nil
    }
    self.playerSupplyTitles = {
        [1] = "",
        [2] = ""
    }

    -- Button animation state
    self.buttonAnimation = self:createDefaultButtonAnimation()

    -- Color themes
    self.colors = self:createDefaultColorTheme()

    -- Player-specific themes
    self.playerThemes = self:createPlayerThemes()

    -- Info panel setup (positioned on left side)
    self.infoPanel = self:createDefaultInfoPanel()

    -- Phase panel and button tracking
    self.phaseButton = nil
    self.lastPhaseButtonHover = false
    self.lastSurrenderButtonHover = false
    -- Track last focused button for keyboard navigation sound
    self.lastKeyboardFocusedButton = nil
    self.lastKeyboardFocusedPanel = nil

    self.phaseButtonLock = {
        active = false,
        phase = nil,
        turnPhase = nil
    }

    self.pulsing = {
        active = false,
        scale = 1.0,
        direction = 1,
        minScale = 0.97,
        maxScale = 1.03,
        speed = 2.5
    }

    self:initializeGameOverPanel()

    self.pressedButton = nil
    self.buttonFeedbackTimer = 0

    -- Keyboard navigation state
    self.uIkeyboardNavigationActive = false  -- True when keyboard navigation is active
    self.navigationMode = "grid"  -- Either "grid" or "ui"
    self.activeUIElement = nil    -- Currently focused UI element
    self.uiElements = {}          -- List of navigable UI elements
    self.currentUIElementIndex = nil  -- Index of current UI element
    self.forceInfoPanelDefault = false
    self.keyboardNavInitiated = false

    self.surrenderButton = self:createDefaultSurrenderButton()
    self.scenarioControlPanel = nil
    self.scenarioObjectivePanel = nil
    self.scenarioObjectiveCommandantSprite = nil
    self.scenarioObjectiveSpritePath = nil
    self.scenarioBackButton = self:createDefaultScenarioControlButton("BACK", "back")
    self.scenarioRetryButton = self:createDefaultScenarioControlButton("RETRY", "retry")
    self.lastScenarioBackButtonHover = false
    self.lastScenarioRetryButtonHover = false

    local success, image = pcall(love.graphics.newImage, "assets/sprites/selectionPointer.png")
    if success then
        self.uiSelectionPointerImage = image
    else
        self.uiSelectionPointerImage = nil
    end

    

    local arrowSuccess, arrowImage = pcall(love.graphics.newImage, "assets/sprites/arrowUi.png")
    if arrowSuccess then
        self.uiArrowImage = arrowImage
    else
        self.uiArrowImage = nil
    end

    -- Load card template background
    local cardSuccess, cardImage = pcall(love.graphics.newImage, "assets/sprites/CardTemplateFront.png")
    if cardSuccess then
        self.cardTemplateImage = cardImage
    else
        self.cardTemplateImage = nil
    end

    -- Typewriter effect state
    self.typewriter = {
        text = "",
        displayedText = "",
        currentIndex = 0,
        speed = 0.05, -- seconds per character
        timer = 0,
        isActive = false,
        lastText = ""
    }
    
    -- Turn zoom effect state
    self.turnZoom = {
        isActive = false,
        scale = 1.0,
        timer = 0,
        duration = 0.4, -- Total zoom effect duration (faster)
        maxScale = 1.15, -- Less zoom for subtler effect
        colorIntensity = 1.0 -- Color intensity (1.0 = normal, higher = whiter)
    }
    
    -- Speech bubble triangle animation state
    self.bubbleTriangle = {
        offsetX = 0,
        offsetY = 0,
        scale = 1.0,
        timer = 0,
        wiggleSpeed = 2.5, -- cycles per second
        wiggleAmount = 3,   -- pixels
        pulseSpeed = 1.8,   -- cycles per second
        pulseAmount = 0.15  -- scale variation
    }

    return self
end


function uiClass:playUISound(path, volume)
    if not SETTINGS.AUDIO.SFX or not path then
        return nil
    end

    return soundCache.play(path, {
        volume = volume or SETTINGS.AUDIO.SFX_VOLUME,
        clone = true
    })
end

-- Helper function to play button beep sound (phase/MOM buttons)
function uiClass:playButtonBeep()
    self:playUISound(self.buttonBeepSoundPath)
end

-- Helper function to play supply panel beep sound
function uiClass:playSupplyBeep()
    self:playUISound(self.supplyBeepSoundPath)
end

--------------------------------------------------
-- INITIALIZATION HELPERS
--------------------------------------------------

function uiClass:createDefaultButtonAnimation()
    return {
        active = false,
        duration = 0.15,
        timer = 0,
        x = 0,
        y = 0,
        width = 0,
        height = 0
    }
end

-- Function to initialize the game over panel
function uiClass:createDefaultColorTheme()
    local colors = uiTheme.COLORS
    return {
        background = colors.background,
        panel = colors.background,
        border = colors.border,
        text = colors.text,
        highlight = colors.highlight,
        button = colors.button,
        buttonHover = colors.buttonHover,
        buttonPressed = colors.buttonPressed
    }
end

function uiClass:createPlayerThemes()
    return {
        [0] = { -- Neutral/building
            panel = {45/255, 39/255, 37/255},
            border = {58/255, 48/255, 40/255},
            highlight = {127/255, 164/255, 168/255},
            text = {203/255, 183/255, 158/255}
        },
        [1] = { -- Player 1 (cats)
            panel = {46/255, 38/255, 32/255, 0.9},
            border = {108/255, 88/255, 66/255, 1.0},
            highlight = {79/255, 62/255, 46/255, 0.9},
            text = {203/255, 183/255, 158/255, 0.95}
        },
        [2] = { -- Player 2 (cows)
            panel = {46/255, 38/255, 32/255, 0.9},
            border = {108/255, 88/255, 66/255, 1.0},
            highlight = {79/255, 62/255, 46/255, 0.9},
            text = {203/255, 183/255, 158/255, 0.95}
        }
    }
end

function uiClass:createDefaultInfoPanel()
    return {
        x = 30,      -- Left side of screen
        y = 410,     -- Vertical position
        width = self.panelWidth,
        height = self.panelHeight,
        title = "INFO",
        content = {},
        theme = self.playerThemes[1], -- Default to player 1 theme
        displayUnit = nil,            -- Store the currently displayed unit
        displayUnitPlayer = nil       -- Store the player of the displayed unit
    }
end

function uiClass:createDefaultSurrenderButton()
    return {
        x = 0,
        y = 0,
        width = 0,
        height = 0,
        text = "M.O.M.",
        actionType = "surrender",
        normalColor = {0.2, 0.4, 0.8, 0.9},   -- Default to blue theme
        hoverColor = {0.3, 0.5, 0.9, 0.95},   -- Default to blue theme
        pressedColor = {0.15, 0.3, 0.6, 0.9}, -- Default to blue theme
        currentColor = {0.2, 0.4, 0.8, 0.9}   -- Start with blue theme
    }
end

function uiClass:createDefaultScenarioControlButton(text, variant)
    local isRetry = variant == "retry"
    local normalColor = isRetry and {0.8, 0.2, 0.2, 0.9} or {0.2, 0.4, 0.8, 0.9}
    local hoverColor = isRetry and {0.9, 0.3, 0.3, 0.95} or {0.3, 0.5, 0.9, 0.95}
    local pressedColor = isRetry and {0.6, 0.15, 0.15, 0.9} or {0.15, 0.3, 0.6, 0.9}

    return {
        x = 0,
        y = 0,
        width = 0,
        height = 0,
        text = text,
        normalColor = normalColor,
        hoverColor = hoverColor,
        pressedColor = pressedColor,
        currentColor = cloneColor(normalColor)
    }
end

--------------------------------------------------
-- ACCESSOR / UTILITY METHODS
--------------------------------------------------
function uiClass:drawSupplyUnitIndicator(x, y, size, player, index)
    if not self.uiSelectionPointerImage then
        return
    end

    -- Only show indicator for selected units (using SAME COLORS AS GRID)
    if self.selectedUnitPlayer == player and self.selectedUnitIndex == index then
        -- Get PLAYER COLOR for selection (same as grid system)
        local indicatorColor
        if player == 1 then
            indicatorColor = {0.3, 0.7, 1.0, 0.9}  -- Blue for player 1 (same as grid)
        elseif player == 2 then
            indicatorColor = {1.0, 0.5, 0.4, 0.9}  -- Red for player 2 (same as grid)
        else
            indicatorColor = {0.4, 0.8, 0.4, 0.9}  -- Green for neutral (same as grid)
        end

        -- Calculate indicator position and size - LARGER than unit icon
        local indicatorSize = size * 1.1  -- 10% larger than the unit icon
        local centerX = x + size / 2
        local centerY = y + size / 2

        -- Static display for selected units (matching grid behavior - NO ANIMATION)
        local alpha = 0.9

        -- Apply player color and alpha
        love.graphics.setColor(indicatorColor[1], indicatorColor[2], indicatorColor[3], alpha)

        -- Draw the PNG indicator (static, no animation)
        love.graphics.draw(
            self.uiSelectionPointerImage,
            centerX, centerY,
            0, -- rotation
            indicatorSize / self.uiSelectionPointerImage:getWidth(),
            indicatorSize / self.uiSelectionPointerImage:getHeight(),
            self.uiSelectionPointerImage:getWidth() / 2,    -- origin X (center)
            self.uiSelectionPointerImage:getHeight() / 2    -- origin Y (center)
        )

        -- Reset color
        love.graphics.setColor(1, 1, 1, 1)
    end
end

-- Function to update supply arrays from gameRuler
function uiClass:updateSupplyFromGameRuler()
    if not self.gameRuler then
        return
    end
    local assignments = GAME.CURRENT.FACTION_ASSIGNMENTS or {}

    -- Panel 1 always shows faction 1 (cats), panel 2 faction 2 (cows)
    local faction1Id = 1
    local faction2Id = 2

    local controller1Id = assignments[faction1Id]
    local controller2Id = assignments[faction2Id]

    local controller1 = GAME.getController(controller1Id)
    local controller2 = GAME.getController(controller2Id)

    self.playerSupplyControllers[1] = controller1
    self.playerSupplyControllers[2] = controller2

    self.playerSupply1 = self.gameRuler.playerSupplies and self.gameRuler.playerSupplies[faction1Id] or {}
    self.playerSupply2 = self.gameRuler.playerSupplies and self.gameRuler.playerSupplies[faction2Id] or {}

    self.playerSupply1Faction = faction1Id
    self.playerSupply2Faction = faction2Id

    self.playerSupply1Owner = faction1Id
    self.playerSupply2Owner = faction2Id

    self.playerSupplyTitles[1] = self:buildSupplyPanelTitle(controller1, Factions.getById(faction1Id))
    self.playerSupplyTitles[2] = self:buildSupplyPanelTitle(controller2, Factions.getById(faction2Id))
end

function uiClass:buildSupplyPanelTitle(controller, faction)
    local nickname = self:getControllerNickname(controller)
    if nickname then
        return nickname
    end

    if faction and faction.supplyPanelTitle then
        return faction.supplyPanelTitle
    end

    return "SUPPLY"
end

function uiClass:getControllerNickname(controller)
    if not controller then
        return nil
    end
    if controller.nickname and controller.nickname ~= "" then
        return controller.nickname
    end
    return controller.id
end

function uiClass:isOnlineNonLocalTurn(phaseInfo)
    if GAME.CURRENT.MODE ~= GAME.MODE.MULTYPLAYER_NET then
        return false
    end
    if not phaseInfo or not phaseInfo.currentPlayer then
        return false
    end
    return not GAME.isFactionControlledLocally(phaseInfo.currentPlayer)
end

function uiClass:resolveSurrenderFactionId()
    if GAME and GAME.CURRENT and GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET then
        if GAME.getLocalFactionId then
            local localFaction = GAME.getLocalFactionId()
            if localFaction == 1 or localFaction == 2 then
                return localFaction
            end
        end

        for factionId = 1, 2 do
            if GAME.isFactionControlledLocally and GAME.isFactionControlledLocally(factionId) then
                return factionId
            end
        end
    end

    if self.gameRuler and (self.gameRuler.currentPlayer == 1 or self.gameRuler.currentPlayer == 2) then
        return self.gameRuler.currentPlayer
    end

    return 1
end

function uiClass:getNowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    if os and os.clock then
        return os.clock()
    end
    return 0
end

function uiClass:isScenarioControlPanelEnabled()
    return self.hideSupplyPanels == true
        and GAME
        and GAME.CURRENT
        and GAME.MODE
        and GAME.CURRENT.MODE == GAME.MODE.SCENARIO
end

function uiClass:updateScenarioControlLayout()
    if not self:isScenarioControlPanelEnabled() then
        return false
    end

    local panelX = SETTINGS.DISPLAY.WIDTH - 250
    local panelY = 50
    local panelWidth = 220
    local panelHeight = 260

    self.scenarioControlPanel = self.scenarioControlPanel or {}
    self.scenarioControlPanel.x = panelX
    self.scenarioControlPanel.y = panelY
    self.scenarioControlPanel.width = panelWidth
    self.scenarioControlPanel.height = panelHeight

    self.scenarioBackButton = self.scenarioBackButton or self:createDefaultScenarioControlButton("BACK", "back")
    self.scenarioRetryButton = self.scenarioRetryButton or self:createDefaultScenarioControlButton("RETRY", "retry")

    local padding = 12
    local spacing = 10
    local buttonHeight = 34
    local buttonY = panelY + panelHeight - buttonHeight - 16
    local buttonWidth = math.floor((panelWidth - (padding * 2) - spacing) / 2)

    self.scenarioBackButton.x = panelX + padding
    self.scenarioBackButton.y = buttonY
    self.scenarioBackButton.width = buttonWidth
    self.scenarioBackButton.height = buttonHeight
    if not self.scenarioBackButton.currentColor then
        self.scenarioBackButton.currentColor = cloneColor(self.scenarioBackButton.normalColor)
    end

    self.scenarioRetryButton.x = self.scenarioBackButton.x + buttonWidth + spacing
    self.scenarioRetryButton.y = buttonY
    self.scenarioRetryButton.width = buttonWidth
    self.scenarioRetryButton.height = buttonHeight
    if not self.scenarioRetryButton.currentColor then
        self.scenarioRetryButton.currentColor = cloneColor(self.scenarioRetryButton.normalColor)
    end

    return true
end

function uiClass:updateScenarioObjectiveLayout()
    if not self:isScenarioControlPanelEnabled() then
        return false
    end

    local panelX = 30
    local panelY = 50
    local panelWidth = 220
    local panelHeight = 260

    self.scenarioObjectivePanel = self.scenarioObjectivePanel or {}
    self.scenarioObjectivePanel.x = panelX
    self.scenarioObjectivePanel.y = panelY
    self.scenarioObjectivePanel.width = panelWidth
    self.scenarioObjectivePanel.height = panelHeight
    return true
end

function uiClass:ensureScenarioObjectiveCommandantSprite()
    if self.scenarioObjectiveCommandantSprite then
        return self.scenarioObjectiveCommandantSprite
    end

    local spritePath = "assets/sprites/Blu_General.png"
    local commandantInfo = self.unitsInfo and self.unitsInfo.getUnitInfo and self.unitsInfo:getUnitInfo("Commandant") or nil
    if type(commandantInfo) == "table" then
        spritePath = commandantInfo.pathUiIcon or commandantInfo.path or spritePath
    end

    local ok, image = pcall(love.graphics.newImage, spritePath)
    if ok and image then
        self.scenarioObjectiveCommandantSprite = image
        self.scenarioObjectiveSpritePath = spritePath
        return image
    end

    return nil
end

function uiClass:getScenarioAttemptsCount()
    local scenarioState = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
    local attempts = tonumber(scenarioState and scenarioState.attempts) or 0
    return math.max(0, math.floor(attempts))
end

function uiClass:getScenarioCode()
    local scenarioState = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
    local code = scenarioState and tostring(scenarioState.id or "") or ""
    if code == "" then
        return "---"
    end
    return code
end

function uiClass:getScenarioWinningConditionsText()
    local scenarioState = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
    local objectiveText = scenarioState and (scenarioState.objectiveMessage or scenarioState.objectiveText) or nil
    if type(objectiveText) == "string" and objectiveText ~= "" then
        local normalized = objectiveText
            :gsub("Rounds", "Turns")
            :gsub("Round", "Turn")
            :gsub("rounds", "turns")
            :gsub("round", "turn")
            :gsub("^%s*[Bb][Ll][Uu][Ee]?%s+to%s+move[,%.:%-]*%s*", "Winning conditions: ")
        return normalized
    end

    local turnsTarget = scenarioState and tonumber(scenarioState.turnsTarget) or nil
    local turnsText = turnsTarget and turnsTarget > 0 and tostring(math.floor(turnsTarget)) or "N#"
    return "Winning conditions: destroy enemy commandant in " .. turnsText .. " turns."
end

function uiClass:getScenarioElapsedSeconds()
    local timer = self.gameRuler and self.gameRuler.gameTimer or nil
    if type(timer) ~= "table" then
        return 0
    end

    local elapsed
    if timer.isRunning then
        elapsed = tonumber(timer.runningDuration)
        if not elapsed then
            local startTime = tonumber(timer.startTime) or self:getNowSeconds()
            elapsed = self:getNowSeconds() - startTime
        end
    else
        elapsed = tonumber(timer.totalGameTime) or tonumber(timer.runningDuration)
    end

    return math.max(0, elapsed or 0)
end

function uiClass:formatElapsedClock(totalSeconds)
    local rounded = math.max(0, math.floor(tonumber(totalSeconds) or 0))
    local minutes = math.floor(rounded / 60)
    local seconds = rounded % 60
    return string.format("%02d:%02d", minutes, seconds)
end

function uiClass:triggerScenarioBackAction()
    if not self:isScenarioControlPanelEnabled() then
        return false
    end

    ConfirmDialog.show(
        "Back to scenario list?",
        function()
            local handled = false
            if type(self.onScenarioBackRequested) == "function" then
                handled = self.onScenarioBackRequested() ~= false
            end
            if not handled and self.stateMachineRef and self.stateMachineRef.changeState then
                self.stateMachineRef.changeState("scenarioSelect")
            end
        end,
        function() end
    )
    return true
end

function uiClass:triggerScenarioRetryAction()
    if not self:isScenarioControlPanelEnabled() then
        return false
    end

    ConfirmDialog.show(
        "Retry this scenario from the start?",
        function()
            local handled = false
            if type(self.onScenarioRetryRequested) == "function" then
                handled = self.onScenarioRetryRequested() ~= false
            end
            if handled then
                return
            end

            local scenarioState = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
            if type(scenarioState) == "table" then
                scenarioState.attempts = math.max(0, tonumber(scenarioState.attempts) or 0) + 1
                scenarioState.solved = false
            end
            if GAME and GAME.CURRENT and GAME.MODE then
                GAME.CURRENT.SCENARIO_RESULT = nil
                GAME.CURRENT.SCENARIO_REQUESTED_MODE = GAME.MODE.SCENARIO
                GAME.CURRENT.MODE = GAME.MODE.SCENARIO
            end
            if self.stateMachineRef and self.stateMachineRef.changeState then
                self.stateMachineRef.changeState("scenarioGameplay")
            end
        end,
        function() end
    )
    return true
end

function uiClass:handleScenarioControlButtonsClick(mouseX, mouseY)
    if not self:updateScenarioControlLayout() then
        return false
    end

    if self.scenarioBackButton
        and mouseX >= self.scenarioBackButton.x and mouseX <= self.scenarioBackButton.x + self.scenarioBackButton.width
        and mouseY >= self.scenarioBackButton.y and mouseY <= self.scenarioBackButton.y + self.scenarioBackButton.height then
        self:activateButtonAnimation(self.scenarioBackButton)
        return self:triggerScenarioBackAction()
    end

    if self.scenarioRetryButton
        and mouseX >= self.scenarioRetryButton.x and mouseX <= self.scenarioRetryButton.x + self.scenarioRetryButton.width
        and mouseY >= self.scenarioRetryButton.y and mouseY <= self.scenarioRetryButton.y + self.scenarioRetryButton.height then
        self:activateButtonAnimation(self.scenarioRetryButton)
        return self:triggerScenarioRetryAction()
    end

    return false
end

function uiClass:canShowOnlineReactionButtons(phaseInfo)
    if GAME.CURRENT.MODE ~= GAME.MODE.MULTYPLAYER_NET then
        return false
    end
    if not phaseInfo then
        return false
    end
    if phaseInfo.currentPhase ~= "turn" or phaseInfo.turnPhaseName ~= "actions" then
        return false
    end
    return self:isOnlineNonLocalTurn(phaseInfo)
end

function uiClass:getOnlineReactionDefinitions()
    return ONLINE_REACTION_DEFINITIONS
end

function uiClass:getOnlineReactionCooldownRemaining()
    local now = self:getNowSeconds()
    local remaining = (self.onlineReactionButtons.cooldownUntil or 0) - now
    if remaining <= 0 then
        return 0
    end
    return remaining
end

function uiClass:setOnlineReactionCooldown(seconds)
    local duration = math.max(0, tonumber(seconds) or 0)
    self.onlineReactionButtons.cooldownUntil = self:getNowSeconds() + duration
end

function uiClass:clearOnlineReactionButtonsLayout()
    self.onlineReactionButtons.buttons = {}
    if self.onlineReactionButtons.lastHoverName then
        self.onlineReactionButtons.lastHoverName = nil
    end
end

function uiClass:getOnlineReactionButtonByName(name)
    local buttons = self.onlineReactionButtons and self.onlineReactionButtons.buttons or {}
    for _, button in ipairs(buttons) do
        if button.name == name then
            return button
        end
    end
    return nil
end

function uiClass:getOnlineReactionButtons()
    return (self.onlineReactionButtons and self.onlineReactionButtons.buttons) or {}
end

function uiClass:isReactionButtonName(name)
    return type(name) == "string" and name:match("^reactionButton_") ~= nil
end

function uiClass:layoutOnlineReactionButtons(x, y, width, height)
    local buttons = {}
    local definitions = self:getOnlineReactionDefinitions()
    local padding = 15
    local gap = 8
    local totalWidth = width - padding * 2
    local buttonCount = #definitions
    if buttonCount <= 0 then
        self.onlineReactionButtons.buttons = buttons
        return buttons
    end

    local buttonHeight = 40
    local buttonWidth = math.floor((totalWidth - (gap * (buttonCount - 1))) / buttonCount)
    local startX = x + padding
    local buttonY = y + height - buttonHeight - padding + 12
    local cooldownActive = self:getOnlineReactionCooldownRemaining() > 0

    for index, definition in ipairs(definitions) do
        local button = self.onlineReactionButtons.buttons[index] or {}
        button.name = "reactionButton_" .. tostring(definition.id)
        button.type = "button"
        button.reactionId = definition.id
        button.text = definition.label
        button.label = definition.label
        button.message = definition.message
        button.variant = definition.variant
        button.x = startX + (index - 1) * (buttonWidth + gap)
        button.y = buttonY
        button.width = buttonWidth
        button.height = buttonHeight
        button.centerText = true
        button.disabledVisual = cooldownActive
        local variant = cooldownActive and uiTheme.BUTTON_VARIANTS.disabled or (uiTheme.BUTTON_VARIANTS[definition.variant] or uiTheme.BUTTON_VARIANTS.default)
        button.normalColor = cloneColor(variant.base)
        button.hoverColor = cloneColor(variant.hover)
        button.pressedColor = cloneColor(variant.pressed)
        button.borderColor = cloneColor(variant.border)
        button.textColor = cloneColor(variant.text)
        button.currentColor = cloneColor(button.normalColor)
        button.focused = false
        buttons[#buttons + 1] = button
    end

    self.onlineReactionButtons.buttons = buttons
    return buttons
end

function uiClass:drawOnlineReactionButtons(x, y, width, height, phaseInfo)
    local buttons = self:layoutOnlineReactionButtons(x, y, width, height)
    local mouseX, mouseY = love.mouse.getPosition()
    local tx = (mouseX - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (mouseY - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
    local hoveredName = nil

    for _, button in ipairs(buttons) do
        local isMouseHovered = tx >= button.x and tx <= button.x + button.width and ty >= button.y and ty <= button.y + button.height
        local isKeyboardFocused = self.uIkeyboardNavigationActive and self.activeUIElement and self.activeUIElement.name == button.name
        button.focused = isKeyboardFocused

        if button.disabledVisual then
            button.currentColor = cloneColor(button.normalColor)
        elseif isMouseHovered or isKeyboardFocused then
            button.currentColor = cloneColor(button.hoverColor)
            if isMouseHovered then
                hoveredName = button.name
            end
        else
            button.currentColor = cloneColor(button.normalColor)
        end

        uiTheme.drawButton(button)
    end

    if hoveredName == nil and not self.uIkeyboardNavigationActive then
        self.onlineReactionButtons.lastHoverName = nil
    end
end

function uiClass:handleOnlineReactionButtonClick(mouseX, mouseY)
    local phaseInfo = self.gameRuler and self.gameRuler.getCurrentPhaseInfo and self.gameRuler:getCurrentPhaseInfo() or nil
    if not self:canShowOnlineReactionButtons(phaseInfo) then
        return false
    end

    local buttons = self:getOnlineReactionButtons()
    if #buttons == 0 then
        return false
    end

    for _, button in ipairs(buttons) do
        if mouseX >= button.x and mouseX <= button.x + button.width and
           mouseY >= button.y and mouseY <= button.y + button.height then
            if button.disabledVisual then
                return true
            end

            self:activateButtonAnimation(button)
            self:playButtonBeep()
            if type(self.onOnlineReactionRequested) == "function" then
                return self.onOnlineReactionRequested(button.reactionId) == true
            end
            return true
        end
    end

    return false
end

function uiClass:showOnlineReactionNotification(payload)
    payload = payload or {}
    local reactionId = tostring(payload.reactionId or "")
    if reactionId == "" then
        return false
    end

    local reactionMessage = reactionId
    for _, definition in ipairs(self:getOnlineReactionDefinitions()) do
        if definition.id == reactionId then
            reactionMessage = definition.message
            break
        end
    end

    local senderFaction = tonumber(payload.senderFaction)
    local senderName = payload.senderName
    if (not senderName or senderName == "") and (senderFaction == 1 or senderFaction == 2) then
        senderName = self:getFactionDisplayName(senderFaction, "Player " .. tostring(senderFaction))
    end

    self.onlineReactionNotification.visible = true
    self.onlineReactionNotification.startedAt = self:getNowSeconds()
    self.onlineReactionNotification.duration = ONLINE_REACTION_NOTIFICATION_DURATION
    self.onlineReactionNotification.reactionId = reactionId
    self.onlineReactionNotification.senderFaction = senderFaction
    self.onlineReactionNotification.senderName = senderName or "Player"
    self.onlineReactionNotification.message = reactionMessage
    return true
end

function uiClass:drawOnlineReactionNotification()
    local notification = self.onlineReactionNotification
    if not notification or notification.visible ~= true then
        return
    end

    local now = self:getNowSeconds()
    local elapsed = now - (notification.startedAt or now)
    local duration = notification.duration or ONLINE_REACTION_NOTIFICATION_DURATION
    if elapsed >= duration then
        notification.visible = false
        return
    end

    local senderFaction = tonumber(notification.senderFaction) or 1
    local fromTop = senderFaction == 1
    local panelWidth = 320
    local panelHeight = 58
    local panelX = (SETTINGS.DISPLAY.WIDTH - panelWidth) / 2
    local targetY = fromTop and 78 or (SETTINGS.DISPLAY.HEIGHT - panelHeight - 92)
    local startY = fromTop and -panelHeight - 20 or (SETTINGS.DISPLAY.HEIGHT + 20)
    local endY = startY
    local animWindow = 0.35
    local y = targetY
    local alpha = 1

    if elapsed < animWindow then
        local t = elapsed / animWindow
        y = startY + (targetY - startY) * t
        alpha = math.min(1, 0.35 + (0.65 * t))
    elseif elapsed > (duration - animWindow) then
        local t = (elapsed - (duration - animWindow)) / animWindow
        y = targetY + (endY - targetY) * t
        alpha = math.max(0, 1 - t)
    end

    local accent = senderFaction == 2 and uiTheme.COLORS.redTeam or uiTheme.COLORS.blueTeam
    local fill = uiTheme.darken(accent, 0.55)
    local border = uiTheme.lighten(accent, 0.15)
    local textColor = {1, 1, 1, alpha}

    love.graphics.setColor(fill[1], fill[2], fill[3], 0.92 * alpha)
    love.graphics.rectangle("fill", panelX, y, panelWidth, panelHeight, 10, 10)
    love.graphics.setColor(border[1], border[2], border[3], alpha)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", panelX, y, panelWidth, panelHeight, 10, 10)
    love.graphics.setLineWidth(1)

    local titleFont = getMonogramFont(SETTINGS.FONT.DEFAULT_SIZE + 2)
    local bodyFont = getMonogramFont(SETTINGS.FONT.DEFAULT_SIZE)
    local previousFont = love.graphics.getFont()

    love.graphics.setFont(titleFont)
    love.graphics.setColor(textColor)
    love.graphics.printf(string.upper(notification.message or "MESSAGE"), panelX, y + 10, panelWidth, "center")

    love.graphics.setFont(bodyFont)
    love.graphics.setColor(0.95, 0.92, 0.84, alpha)
    love.graphics.printf(tostring(notification.senderName or "Player"), panelX, y + 31, panelWidth, "center")

    love.graphics.setFont(previousFont)
    love.graphics.setColor(1, 1, 1, 1)
end

function uiClass:handleOnlineNonLocalClick(mouseX, mouseY)
    local mode = GAME.CURRENT and GAME.CURRENT.MODE or nil
    local localVariant = tostring((GAME.CURRENT and GAME.CURRENT.LOCAL_MATCH_VARIANT) or "couch")
    local isOnline = mode == GAME.MODE.MULTYPLAYER_NET
    local isRemotePlayLocal = mode == GAME.MODE.MULTYPLAYER_LOCAL and localVariant == "remote_play"
    if not isOnline and not isRemotePlayLocal then
        return false
    end

    if not self.gameRuler or self.gameRuler.currentPhase ~= "turn" or self.gameRuler.currentTurnPhase ~= "actions" then
        return false
    end

    local canClickSurrender = self.surrenderButton and
        mouseX >= self.surrenderButton.x and mouseX <= self.surrenderButton.x + self.surrenderButton.width and
        mouseY >= self.surrenderButton.y and mouseY <= self.surrenderButton.y + self.surrenderButton.height

    local canClickCodex = self.unitCodexButton and
        mouseX >= self.unitCodexButton.x and mouseX <= self.unitCodexButton.x + self.unitCodexButton.width and
        mouseY >= self.unitCodexButton.y and mouseY <= self.unitCodexButton.y + self.unitCodexButton.height

    local canClickGameLog = self.gameLogPanel and
        mouseX >= self.gameLogPanel.x and mouseX <= self.gameLogPanel.x + self.gameLogPanel.width and
        mouseY >= self.gameLogPanel.y and mouseY <= self.gameLogPanel.y + self.gameLogPanel.height

    local canClickReaction = false
    if isOnline and self.gameRuler then
        local phaseInfo = self.gameRuler.getCurrentPhaseInfo and self.gameRuler:getCurrentPhaseInfo() or nil
        if self:canShowOnlineReactionButtons(phaseInfo) then
            for _, button in ipairs(self:getOnlineReactionButtons()) do
                if mouseX >= button.x and mouseX <= button.x + button.width and
                   mouseY >= button.y and mouseY <= button.y + button.height then
                    canClickReaction = true
                    break
                end
            end
        end
    end

    if canClickSurrender or canClickGameLog or canClickCodex or canClickReaction then
        return self:handleClickOnUI(mouseX, mouseY)
    end

    return false
end

function uiClass:getFactionDisplayName(factionId, fallbackLabel)
    local nickname = GAME.getFactionControllerNickname and GAME.getFactionControllerNickname(factionId) or nil
    if nickname and nickname ~= "" then
        return tostring(nickname)
    end

    local controller = GAME.getControllerForFaction and GAME.getControllerForFaction(factionId) or nil
    if controller then
        if controller.nickname and controller.nickname ~= "" then
            return tostring(controller.nickname)
        end
        if controller.id and controller.id ~= "" then
            local idText = tostring(controller.id)
            return "Player " .. idText:sub(-6)
        end
    end

    return fallbackLabel or ("Player " .. tostring(factionId or "?"))
end

function uiClass:truncateDisplayName(name, maxChars)
    local text = tostring(name or "")
    local limit = tonumber(maxChars) or 16
    if #text <= limit then
        return text
    end
    if limit <= 1 then
        return text:sub(1, 1)
    end
    return text:sub(1, limit - 1) .. "..."
end

function uiClass:getFactionTheme(factionId)
    if factionId == 1 then
        return self.playerThemes[1]
    elseif factionId == 2 then
        return self.playerThemes[2]
    end
    return self.playerThemes[0]
end

function uiClass:getSupplyFactionForPanel(panelIndex)
    if panelIndex == 1 then
        return self.playerSupply1Faction or 1
    elseif panelIndex == 2 then
        return self.playerSupply2Faction or 2
    end
    return panelIndex or 0
end

function uiClass:getSupplyOwnerForPanel(panelIndex)
    if panelIndex == 1 then
        return self.playerSupply1Owner or 1
    elseif panelIndex == 2 then
        return self.playerSupply2Owner or 2
    end
    return panelIndex or 0
end

function uiClass:getSupplyPanelData(panelIndex)
    local factionId = self:getSupplyFactionForPanel(panelIndex)
    local controller = self.playerSupplyControllers[panelIndex]
    local factionDef = Factions.getById(factionId)
    local theme = self:getFactionTheme(factionId)

    return {
        factionId = factionId,
        controller = controller,
        factionDef = factionDef,
        theme = theme,
        title = self.playerSupplyTitles[panelIndex] or "SUPPLY"
    }
end

local function debugSetContent(self, message)
    if DEBUG and DEBUG.UI then
        if self._debugLastSetContentMsg ~= message then
            self._debugLastSetContentMsg = message
        end
    end
end

local function buildContentMemoKey(content)
    if not content then
        return "__nil__"
    end

    if content.unitObject then
        return table.concat({
            "unit",
            tostring(content.unitObject),
            tostring(content.name or ""),
            tostring(content.player or ""),
            tostring(content.hp or ""),
            tostring(content.move or ""),
            tostring(content.atkRange or ""),
            tostring(content.atkDamage or ""),
            tostring(content.fly or "")
        }, "|")
    end

    return table.concat({
        "content",
        tostring(content.name or ""),
        tostring(content.status or ""),
        tostring(content.panel or ""),
        tostring(content.hp or ""),
        tostring(content.move or ""),
        tostring(content.atkRange or ""),
        tostring(content.atkDamage or ""),
        tostring(content.fly or "")
    }, "|")
end

function uiClass:setContent(content, theme)
    local activeTheme = theme or self.playerThemes[0]
    local contentMemoKey = buildContentMemoKey(content)
    if self._lastSetContentMemoKey == contentMemoKey and self._lastSetContentTheme == activeTheme then
        return true
    end

    if not content then
        self.infoPanel.content = {}
        self.infoPanel.theme = self.playerThemes[0]
        self.infoPanel.title = ""
        self.infoPanel.displayUnit = nil
        self.infoPanel.displayUnitPlayer = nil
        self._lastSetContentMemoKey = contentMemoKey
        self._lastSetContentTheme = self.playerThemes[0]
        return true
    end

    self.infoPanel.content = content
    self.infoPanel.theme = activeTheme

    if content.name then
        self.infoPanel.title = string.upper(content.name)
    else
        self.infoPanel.title = ""
    end

    -- Rehydrate selected supply unit if index is known but unit reference was cleared
    if (not self.selectedUnit) and self.selectedUnitIndex and self.gameRuler then
        local supplyList = self.gameRuler:getCurrentPlayerSupply(self.selectedUnitOwner or self.gameRuler.currentPlayer)
        if supplyList and supplyList[self.selectedUnitIndex] then
            self.selectedUnit = supplyList[self.selectedUnitIndex]
        end
    end

    if content.unitObject then
        -- This is a unit object from the grid OR from the supply
        self.infoPanel.displayUnit = content.unitObject
        self.infoPanel.displayUnitPlayer = content.player or 0

        local isCurrentSupplySelection = (content.unitObject == self.selectedUnit and content.player == self.selectedUnitPlayer)
        local inDeploymentPhase = self.gameRuler and (self.gameRuler.currentPhase == "deploy1_units" or self.gameRuler.currentPhase == "deploy2_units")

        if isCurrentSupplySelection then
            -- Maintain supply selection state when the content refers to the selected supply unit
            self.selectedSource = "supply"
            debugSetContent(self, "content refers to current supply selection")
        elseif inDeploymentPhase and self.selectedSource == "supply" and self.selectedUnitIndex then
            -- During deployment, keep the previously selected supply unit even when inspecting grid units
            debugSetContent(self, "preserving supply selection while inspecting grid unit")
        else
            -- Otherwise treat this as a grid selection and clear any lingering supply selection
            self.selectedSource = "grid"
            self.selectedUnit = nil
            self.selectedUnitPlayer = nil
            self.selectedUnitIndex = nil
            self.selectedUnitCoordOnPanel = nil
            debugSetContent(self, "cleared supply selection (grid content)")
        end

    elseif content.status and content.status == "Empty Cell" then
        -- Clear info panel visuals for empty cell
        self.infoPanel.displayUnit = nil
        self.infoPanel.displayUnitPlayer = nil

        local inDeploymentPhase = self.gameRuler and (self.gameRuler.currentPhase == "deploy1_units" or self.gameRuler.currentPhase == "deploy2_units")

        local hasSupplySelection = self.selectedUnitIndex ~= nil
        if (not self.selectedUnit) and hasSupplySelection and self.gameRuler then
            local supplyList = self.gameRuler:getCurrentPlayerSupply(self.selectedUnitPlayer or self.gameRuler.currentPlayer)
            if supplyList and supplyList[self.selectedUnitIndex] then
                self.selectedUnit = supplyList[self.selectedUnitIndex]
            end
        end
        if self.selectedSource ~= "supply" and hasSupplySelection then
            -- Recover supply source flag if selection is still active
            self.selectedSource = "supply"
            debugSetContent(self, "recovered supply selection flag")
        end

        if self.selectedSource == "supply" and hasSupplySelection then
            if inDeploymentPhase then
                -- Keep supply selection active while highlighting eligible deployment cells
                debugSetContent(self, "empty cell retains supply selection during deployment")
            else
                -- Outside deployment phases we can clear the selection
                self.selectedUnit = nil
                self.selectedUnitPlayer = nil
                self.selectedUnitOwner = nil
                self.selectedUnitIndex = nil
                self.selectedUnitCoordOnPanel = nil
                self.selectedSource = nil
                debugSetContent(self, "empty cell cleared selection (not in deployment)")
            end
        else
            -- No active supply selection to preserve
            self.selectedUnit = nil
            self.selectedUnitPlayer = nil
            self.selectedUnitOwner = nil
            self.selectedUnitIndex = nil
            self.selectedUnitCoordOnPanel = nil
            self.selectedSource = nil
            debugSetContent(self, "empty cell cleared selection (no supply source)")
        end

    elseif self.selectedUnit then
        -- This is from a supply unit selection
        self.infoPanel.displayUnit = self.selectedUnit
        self.infoPanel.displayUnitPlayer = self.selectedUnitPlayer
        self.selectedSource = "supply"
        debugSetContent(self, "showing selected supply unit in info panel")

    elseif self.hoveredUnit then
        -- This is from a supply unit selection
        self.infoPanel.displayUnit = self.hoveredUnit
        self.infoPanel.displayUnitPlayer = self.hoveredUnitPlayer
        self.selectedSource = "supply"
        debugSetContent(self, "showing hovered supply unit in info panel")

    else
        -- just clear display
        self.infoPanel.displayUnit = nil
        self.infoPanel.displayUnitPlayer = nil
        self.selectedSource = nil
        debugSetContent(self, "cleared info panel content")
    end

    self._lastSetContentMemoKey = contentMemoKey
    self._lastSetContentTheme = activeTheme
    return true
end

function uiClass:getRandomNeutralBuildingPosition()
    local minRow = 1
    local maxRow = GAME.CONSTANTS.GRID_SIZE
    local minCol = 1
    local maxCol = GAME.CONSTANTS.GRID_SIZE
    local row = math.random(minRow, maxRow)
    local col = math.random(minCol, maxCol)
    return row, col
end

function uiClass:getUnitColor(unit)
    if not unit or not unit.name then
        return {0.5, 0.5, 0.5}  -- Default gray
    end

    local colors = {
        ["Commandant"]   = {0.8, 0.8, 0.2},  -- Gold
        ScoutDrone   = {0.2, 0.8, 0.8},  -- Cyan
        AssaultMech  = {0.8, 0.2, 0.2},  -- Red
        GigaMech     = {0.5, 0.5, 0.5},  -- Gray
        Corvette     = {0.2, 0.2, 0.8},  -- Blue
        HunterMech   = {0.8, 0.4, 0.2},  -- Orange
        RepairDrone  = {0.2, 0.8, 0.2},  -- Green
        Building     = {0.8, 0.6, 0.4},  -- Tan for buildings
        ["Rock"] = {0.8, 0.6, 0.4}  -- Also for Rocks
    }

    local unitType = unit.name
    if type(unitType) == "string" then
        unitType = unitType:gsub(" ", "")
    end

    return colors[unitType] or {0.5, 0.5, 0.5}  -- Default gray
end

--------------------------------------------------
-- INTERACTION METHODS
--------------------------------------------------
function uiClass:handleMouseMovement(mouseX, mouseY, grid)
    self.keyboardNavInitiated = false

    if self.uIkeyboardNavigationActive and self.navigationMode == "ui" then
        return false
    end

    if self.overlayInputBlocked then
        self:clearHoveredInfo()
        self:clearGameLogPanelHover()
        if grid then
            grid:forceHideHoverIndicator()
        end
        return true
    end
    
    -- In AI vs AI mode, block all mouse hover effects except the phase button
    if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI then
        self:clearGameLogPanelHover()
        return false
    end

    local inGameOver = self.gameRuler and self.gameRuler.currentPhase == "gameOver"
    local gameOverPanelVisible = inGameOver and self.gameOverPanel and self.gameOverPanel.visible
    local battlefieldView = inGameOver and self.gameOverPanel and not self.gameOverPanel.visible

    local foundHoveredUnit = false
    local hoverBuffer = 10
    local isHoveringUIElement = false -- Track if we're hovering over any UI element

    if not inGameOver then
        -- Check if mouse is over ANY cell in the supply panels (including empty cells)
        for _, unitPos in ipairs(self.unitPositions) do
            if mouseX >= unitPos.x - hoverBuffer and mouseX <= unitPos.x + unitPos.size + hoverBuffer and 
               mouseY >= unitPos.y - hoverBuffer and mouseY <= unitPos.y + unitPos.size + hoverBuffer then

                -- Check if this is a different supply cell than the previous one
                local currentSupplyKey = unitPos.panelPlayer .. "_" .. unitPos.index
                if not self.lastMouseSupplyKey or self.lastMouseSupplyKey ~= currentSupplyKey then
                    -- Play supply panel beep sound
                    self:playSupplyBeep()
                    self.lastMouseSupplyKey = currentSupplyKey
                end

                -- Store hovered unit info (will be nil for empty cells, but store position)
                self.hoveredUnit = unitPos.unit
                -- Use supply faction mapping so colors remain consistent when factions swap
                local panelFaction = self:getSupplyFactionForPanel(unitPos.panelPlayer)
                self.hoveredUnitPlayer = panelFaction or (unitPos.panelPlayer or unitPos.player)
                self.hoveredUnitIndex = unitPos.index
                -- Store coordinates for all cells (empty or not)
                self.hoveredX = unitPos.x
                self.hoveredY = unitPos.y
                
                -- Store the flip type for the hovered supply icon (must match supply icon calculation)
                local iconFaction = unitPos.panelPlayer
                if GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL then
                    if unitPos.panelPlayer == 1 then
                        iconFaction = self.playerSupply1Faction or unitPos.panelPlayer
                    elseif unitPos.panelPlayer == 2 then
                        iconFaction = self.playerSupply2Faction or unitPos.panelPlayer
                    end
                end
                local tintPlayer = iconFaction
                local seed = unitPos.index * 1000 + (tintPlayer or 1) * 100
                self.hoveredSupplyFlipType = randomGen.deterministicRandom(seed, 1, 4)

                -- Create and update the info panel with information
                if not self.selectedUnit then
                    if unitPos.unit then
                        -- Show unit info for cells with units
                        -- Use mapped faction so info panel theme matches displayed colors
                        local panelFaction = self:getSupplyFactionForPanel(unitPos.panelPlayer)
                        local unitInfo = self:createUnitInfoFromUnit(unitPos.unit, panelFaction)
                        self:setContent(unitInfo, self.playerThemes[panelFaction] or self.playerThemes[0])
                    else
                        -- Show empty cell info for empty cells
                        local emptyInfo = {
                            status = "Empty Supply Slot",
                            panel = unitPos.panelPlayer == 1 and "Left Panel" or "Right Panel"
                        }
                        local panelFaction = self:getSupplyFactionForPanel(unitPos.panelPlayer)
                        self:setContent(emptyInfo, self.playerThemes[panelFaction] or self.playerThemes[0])
                    end
                end

                for i, element in ipairs(self.uiElements) do
                    if element.type == "supplyUnit"
                        and element.unitData
                        and element.unitData.panelPlayer == unitPos.panelPlayer
                        and element.unitData.index == unitPos.index then
                        self.currentUIElementIndex = i
                        self.activeUIElement = element
                        break
                    end
                end

                foundHoveredUnit = true
                isHoveringUIElement = true -- Set UI hover flag
                break
            end
        end
    end

    local allowSurrenderHover = false
    if not inGameOver and self.surrenderButton and self.gameRuler then
        if self.gameRuler.currentPhase == "turn" and self.gameRuler.currentTurnPhase == "actions" then
            if GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER then
                allowSurrenderHover = (self.gameRuler.currentPlayer ~= GAME.CURRENT.AI_PLAYER_NUMBER)
            else
                allowSurrenderHover = true
            end
        end
    end

    if allowSurrenderHover then

        local isMouseOverSurrenderButton = mouseX >= self.surrenderButton.x and mouseX <= self.surrenderButton.x + self.surrenderButton.width and
                                          mouseY >= self.surrenderButton.y and mouseY <= self.surrenderButton.y + self.surrenderButton.height
        
        local isKeyboardSelectedSurrender = self.uIkeyboardNavigationActive and self.activeUIElement and 
                                           self.activeUIElement.name == "surrenderButton"
        
        local isSurrenderButtonHovered = isMouseOverSurrenderButton or isKeyboardSelectedSurrender
        
        if isSurrenderButtonHovered then
            self.surrenderButton.currentColor = self.surrenderButton.hoverColor
            if isMouseOverSurrenderButton then
                isHoveringUIElement = true
            end
            
            if self.surrenderButton and mouseX >= self.surrenderButton.x and mouseX <= self.surrenderButton.x + self.surrenderButton.width and
           mouseY >= self.surrenderButton.y and mouseY <= self.surrenderButton.y + self.surrenderButton.height and not self.lastSurrenderButtonHover then
            -- Play button beep sound (MOM button)
            self:playButtonBeep()
            self.lastSurrenderButtonHover = true
            end
        else
            self.surrenderButton.currentColor = self.surrenderButton.normalColor
            -- Only reset hover tracking if not keyboard focused
            if not isKeyboardSelectedSurrender then
                self.lastSurrenderButtonHover = false
            end
        end
    end

    local scenarioPanelActive = (not inGameOver) and self:updateScenarioControlLayout()
    local scenarioObjectivePanelActive = (not inGameOver) and self:updateScenarioObjectiveLayout()
    if scenarioObjectivePanelActive and self.scenarioObjectivePanel then
        local objectivePanel = self.scenarioObjectivePanel
        if mouseX >= objectivePanel.x and mouseX <= objectivePanel.x + objectivePanel.width and
           mouseY >= objectivePanel.y and mouseY <= objectivePanel.y + objectivePanel.height then
            isHoveringUIElement = true
        end
    end
    if scenarioPanelActive then
        local scenarioPanel = self.scenarioControlPanel
        if mouseX >= scenarioPanel.x and mouseX <= scenarioPanel.x + scenarioPanel.width and
           mouseY >= scenarioPanel.y and mouseY <= scenarioPanel.y + scenarioPanel.height then
            isHoveringUIElement = true
        end

        local function updateScenarioButtonHover(button, elementName, hoverFlagName)
            local isMouseOver = mouseX >= button.x and mouseX <= button.x + button.width and
                mouseY >= button.y and mouseY <= button.y + button.height
            local isKeyboardFocused = self.uIkeyboardNavigationActive and self.activeUIElement and
                self.activeUIElement.name == elementName
            local isHovered = isMouseOver or isKeyboardFocused

            if isHovered then
                button.currentColor = button.hoverColor
                if isMouseOver then
                    isHoveringUIElement = true
                end
                if isMouseOver and not self[hoverFlagName] then
                    self:playButtonBeep()
                    self[hoverFlagName] = true
                end
            else
                button.currentColor = button.normalColor
            end

            if not isMouseOver and not isKeyboardFocused then
                self[hoverFlagName] = false
            end
        end

        updateScenarioButtonHover(self.scenarioBackButton, "scenarioBackButton", "lastScenarioBackButtonHover")
        updateScenarioButtonHover(self.scenarioRetryButton, "scenarioRetryButton", "lastScenarioRetryButtonHover")
    else
        if self.scenarioBackButton then
            self.scenarioBackButton.currentColor = self.scenarioBackButton.normalColor
        end
        if self.scenarioRetryButton then
            self.scenarioRetryButton.currentColor = self.scenarioRetryButton.normalColor
        end
        self.lastScenarioBackButtonHover = false
        self.lastScenarioRetryButtonHover = false
    end

    local phaseInfo = self.gameRuler and self.gameRuler.getCurrentPhaseInfo and self.gameRuler:getCurrentPhaseInfo() or nil
    if not inGameOver and self:canShowOnlineReactionButtons(phaseInfo) then
        local hoveredReactionName = nil
        for _, button in ipairs(self:getOnlineReactionButtons()) do
            local isMouseOverReaction = mouseX >= button.x and mouseX <= button.x + button.width and
                mouseY >= button.y and mouseY <= button.y + button.height
            local isKeyboardReaction = self.uIkeyboardNavigationActive and self.activeUIElement and self.activeUIElement.name == button.name

            if button.disabledVisual then
                button.currentColor = cloneColor(button.normalColor)
            elseif isMouseOverReaction or isKeyboardReaction then
                button.currentColor = cloneColor(button.hoverColor)
                if isMouseOverReaction then
                    hoveredReactionName = button.name
                    isHoveringUIElement = true
                end
            else
                button.currentColor = cloneColor(button.normalColor)
            end
        end

        if hoveredReactionName and hoveredReactionName ~= self.onlineReactionButtons.lastHoverName then
            self:playButtonBeep()
        end
        self.onlineReactionButtons.lastHoverName = hoveredReactionName
    else
        self.onlineReactionButtons.lastHoverName = nil
    end

    -- If we're not hovering over any cell, clear the hover state
    if not foundHoveredUnit then
        -- Reset hover state for ALL hover-related variables
        self:clearHoveredInfo()
        if not self.selectedUnit then
            self:setContent(nil)
        end
    end

    -- Game over button hover effects with sound feedback
    if inGameOver then
        -- Only handle mouse hover if keyboard navigation is not active
        if not self.uIkeyboardNavigationActive then
            -- Track previous hover states for sound
            local previousMainMenuHover = (self.gameOverPanel.button.currentColor == self.gameOverPanel.button.hoverColor)
            local previousToggleHover = (self.gameOverPanel.toggleButton.currentColor == self.gameOverPanel.toggleButton.hoverColor)
            local previousReturnHover = (self.gameOverPanel.returnButton.currentColor == self.gameOverPanel.returnButton.hoverColor)
            
            -- Reset all button colors first
            self.gameOverPanel.button.currentColor = self.colors.button
            self.gameOverPanel.toggleButton.currentColor = self.colors.button
            self.gameOverPanel.returnButton.currentColor = self.colors.button
            
            local currentHover = nil
            
            -- Main menu button hover
            if self.gameOverPanel.visible and
               mouseX >= self.gameOverPanel.button.x and mouseX <= self.gameOverPanel.button.x + self.gameOverPanel.button.width and
               mouseY >= self.gameOverPanel.button.y and mouseY <= self.gameOverPanel.button.y + self.gameOverPanel.button.height then
                self.gameOverPanel.button.currentColor = self.gameOverPanel.button.hoverColor
                isHoveringUIElement = true
                currentHover = "mainMenu"
            -- Toggle visibility button hover (only when visible)
            elseif self.gameOverPanel.visible and
               mouseX >= self.gameOverPanel.toggleButton.x and mouseX <= self.gameOverPanel.toggleButton.x + self.gameOverPanel.toggleButton.width and
               mouseY >= self.gameOverPanel.toggleButton.y and mouseY <= self.gameOverPanel.toggleButton.y + self.gameOverPanel.toggleButton.height then
                self.gameOverPanel.toggleButton.currentColor = self.gameOverPanel.toggleButton.hoverColor
                isHoveringUIElement = true
                currentHover = "toggle"
            -- Return to results button hover (when battlefield is visible)
            elseif not self.gameOverPanel.visible and
               mouseX >= self.gameOverPanel.returnButton.x and mouseX <= self.gameOverPanel.returnButton.x + self.gameOverPanel.returnButton.width and
               mouseY >= self.gameOverPanel.returnButton.y and mouseY <= self.gameOverPanel.returnButton.y + self.gameOverPanel.returnButton.height then
                self.gameOverPanel.returnButton.currentColor = self.gameOverPanel.returnButton.hoverColor
                isHoveringUIElement = true
                currentHover = "return"
            end
            
            -- Play navigation sound when hover state changes
            if currentHover and 
               ((currentHover == "mainMenu" and not previousMainMenuHover) or
                (currentHover == "toggle" and not previousToggleHover) or
                (currentHover == "return" and not previousReturnHover)) then
                self:playButtonBeep()
            end
        end

        if gameOverPanelVisible then
            isHoveringUIElement = true
            if grid then
                grid:forceHideHoverIndicator()
            end
            return true
        end
    end

    -- Check phase button hover
    if self.phaseButton then
        local isMouseOverButton = mouseX >= self.phaseButton.x and mouseX <= self.phaseButton.x + self.phaseButton.width and
                                 mouseY >= self.phaseButton.y and mouseY <= self.phaseButton.y + self.phaseButton.height
        
        local isKeyboardSelected = self.uIkeyboardNavigationActive and self.activeUIElement and 
                                  self.activeUIElement.name == "phaseButton"
        
        local isPhaseButtonHovered = isMouseOverButton or isKeyboardSelected
        
        -- Handle mouse hover sound (only trigger once when entering button area)
        if isMouseOverButton then
            if not self.lastPhaseButtonHover then
                self:playButtonBeep()
                self.lastPhaseButtonHover = true
            end
        else
            -- Reset hover flag only when mouse is completely outside button
            self.lastPhaseButtonHover = false
        end
        
        -- Handle visual hover effects
        if isPhaseButtonHovered then
            -- Use theme-appropriate hover colors that match the UI
            if self.phaseButton.hoverColor then
                self.phaseButton.currentColor = self.phaseButton.hoverColor
            else
                -- Fallback to UI theme hover color
                self.phaseButton.currentColor = self.colors.buttonHover
            end
            if isMouseOverButton then
                isHoveringUIElement = true
            end
        else
            self.phaseButton.currentColor = self.phaseButton.normalColor or self.colors.button
        end
    end

    -- Check if hovering over info panel area
    if mouseX >= self.infoPanel.x and mouseX <= self.infoPanel.x + self.infoPanel.width and
       mouseY >= self.infoPanel.y and mouseY <= self.infoPanel.y + self.infoPanel.height + 54 then
        isHoveringUIElement = true
    end

    -- Hide or show hover indicator based on UI element hover state
    if grid then
        if isHoveringUIElement then
            -- Hide the hover indicator when hovering over UI elements
            grid:forceHideHoverIndicator()
        else
            -- Restore normal hover indicator behavior
            grid:restoreHoverIndicator()
        end
    end

    return isHoveringUIElement
end

-- Add this function to restore selected unit info
function uiClass:clearHoveredInfo()
    self.hoveredUnit = nil
    self.hoveredUnitPlayer = nil
    self.hoveredUnitIndex = nil
    self.hoveredSupplyFlipType = nil  -- Clear flip type when clearing hover
    self.hoveredX = nil
    self.hoveredY = nil
    -- Clear mouse supply tracking to ensure sound plays when returning to supply panel
    self.lastMouseSupplyKey = nil
    -- Don't clear button hover tracking here - let the button hover logic handle it
    -- self.lastPhaseButtonHover = false
    -- self.lastSurrenderButtonHover = false
    -- Don't clear keyboard focus tracking here - it should persist during navigation
    -- self.lastKeyboardFocusedButton = nil
end

function uiClass:surrenderGame()
    if not self.gameRuler then return end

    if type(self.onSurrenderRequested) == "function" then
        local ok = self.onSurrenderRequested()
        if ok ~= false then
            return true
        end

        if GAME and GAME.CURRENT and GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET then
            return false
        end
    end

    -- Fallback for modes that don't provide gameplay callback handling.
    local winner = self.gameRuler:getOpponentPlayer()
    self.gameRuler:addLogEntryString("P" .. self.gameRuler.currentPlayer .. " call M.O.M. P" .. winner .. " wins!")
    self.gameRuler.winner = winner
    self.gameRuler:setPhase("gameOver")
    return true
end

function uiClass:clearGameLogPanelHover()
    -- Clear the hover state for game log panel
    self.gameLogPanelPreviousHover = false
    -- Also force clear mouse hover by setting a flag
    self.gameLogPanelForceNoHover = true
    -- Remember the mouse position when we disabled hover
    local mouseX, mouseY = love.mouse.getPosition()
    self.gameLogPanelDisabledMouseX = mouseX
    self.gameLogPanelDisabledMouseY = mouseY
end

function uiClass:handleClickOnUI(mouseX, mouseY)

    self.keyboardNavInitiated = false

    if GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and 
       self.gameRuler and self.gameRuler.currentPlayer == GAME.CURRENT.AI_PLAYER_NUMBER then
        return true
    end

    -- Don't process clicks if confirmation dialog is active
    if ConfirmDialog.isActive() then
        return false
    end

    if self.overlayInputBlocked then
        return false
    end

    local inGameOver = self.gameRuler and self.gameRuler.currentPhase == "gameOver"
    local gameOverPanelVisible = inGameOver and self.gameOverPanel and self.gameOverPanel.visible
    local battlefieldView = inGameOver and self.gameOverPanel and not self.gameOverPanel.visible

    if inGameOver then
        if gameOverPanelVisible then
            if self.gameOverPanel and self.gameOverPanel.button and
               mouseX >= self.gameOverPanel.button.x and mouseX <= self.gameOverPanel.button.x + self.gameOverPanel.button.width and
               mouseY >= self.gameOverPanel.button.y and mouseY <= self.gameOverPanel.button.y + self.gameOverPanel.button.height then
                self:activateButtonAnimation(self.gameOverPanel.button)
                ConfirmDialog.show(
                    "Return to main menu?",
                    function()
                        if self.stateMachineRef and self.stateMachineRef.changeState then
                            self.stateMachineRef.changeState("mainMenu")
                        end
                    end,
                    function() end
                )
                return true
            end

            if self.gameOverPanel and self.gameOverPanel.toggleButton and
               mouseX >= self.gameOverPanel.toggleButton.x and mouseX <= self.gameOverPanel.toggleButton.x + self.gameOverPanel.toggleButton.width and
               mouseY >= self.gameOverPanel.toggleButton.y and mouseY <= self.gameOverPanel.toggleButton.y + self.gameOverPanel.toggleButton.height then
                self:activateButtonAnimation(self.gameOverPanel.toggleButton)
                self.gameOverPanel.visible = false
                self:initializeUIElements()
                if self.gameOverPanel.returnButton then
                    love.mouse.setPosition(
                        self.gameOverPanel.returnButton.x + self.gameOverPanel.returnButton.width / 2,
                        self.gameOverPanel.returnButton.y + self.gameOverPanel.returnButton.height / 2
                    )
                end
                return true
            end

            return true
        end

        if battlefieldView then
            if self.gameOverPanel and self.gameOverPanel.returnButton and
               mouseX >= self.gameOverPanel.returnButton.x and mouseX <= self.gameOverPanel.returnButton.x + self.gameOverPanel.returnButton.width and
               mouseY >= self.gameOverPanel.returnButton.y and mouseY <= self.gameOverPanel.returnButton.y + self.gameOverPanel.returnButton.height then
                self:activateButtonAnimation(self.gameOverPanel.returnButton)
                self.gameOverPanel.visible = true
                self:initializeUIElements()
                if self.gameOverPanel.button then
                    love.mouse.setPosition(
                        self.gameOverPanel.button.x + self.gameOverPanel.button.width / 2,
                        self.gameOverPanel.button.y + self.gameOverPanel.button.height / 2
                    )
                end
                return true
            end

            if self:handleGameLogPanelClick(mouseX, mouseY) then
                return true
            end

            return true
        end
    end

    if not inGameOver and self:handleScenarioControlButtonsClick(mouseX, mouseY) then
        return true
    end

    -- Check for surrender button click
    if not inGameOver and self.surrenderButton and
       mouseX >= self.surrenderButton.x and mouseX <= self.surrenderButton.x + self.surrenderButton.width and
       mouseY >= self.surrenderButton.y and mouseY <= self.surrenderButton.y + self.surrenderButton.height then

        -- Only process click if in the correct phase
        if self.gameRuler and self.gameRuler.currentPhase == "turn" and 
       self.gameRuler.currentTurnPhase == "actions" and
       (GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL or GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET or
        (GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and self.gameRuler.currentPlayer ~= GAME.CURRENT.AI_PLAYER_NUMBER)) then

            -- Animate button
            self:activateButtonAnimation(self.surrenderButton)

            -- Show confirmation dialog
            local surrenderFaction = self:resolveSurrenderFactionId()
            local surrenderText
            if surrenderFaction == 1 then
                surrenderText = "MOO OVER MEOW!\n\nAre you sure you want to concede?"
            else
                surrenderText = "MEOW OVER MOO!\n\nAre you sure you want to concede?"
            end
            ConfirmDialog.show(
                surrenderText,
                function()
                    -- Confirmed surrender
                    self:surrenderGame()
                end,
                function() 
                    -- Cancel action
                end
            )
            return true
        end
    end

    -- Handle game over screen buttons
    if inGameOver then
        -- Main menu button
        if self.gameOverPanel.visible and
           mouseX >= self.gameOverPanel.button.x and
           mouseX <= self.gameOverPanel.button.x + self.gameOverPanel.button.width and
           mouseY >= self.gameOverPanel.button.y and
           mouseY <= self.gameOverPanel.button.y + self.gameOverPanel.button.height then

            -- Use the same animation system as other buttons
            self:activateButtonAnimation(self.gameOverPanel.button)

            -- Show confirmation dialog with proper callbacks
            ConfirmDialog.show(
                "Return to main menu?", 
                function() 
                    if self.stateMachineRef and self.stateMachineRef.changeState then
                        self.stateMachineRef.changeState("mainMenu")
                    end
                end,
                function() 
                    -- Do nothing when cancel is clicked
                end
            )
            return true
        end

        -- Toggle button (similar pattern)
        if self.gameOverPanel.visible and
           mouseX >= self.gameOverPanel.toggleButton.x and
           mouseX <= self.gameOverPanel.toggleButton.x + self.gameOverPanel.toggleButton.width and
           mouseY >= self.gameOverPanel.toggleButton.y and
           mouseY <= self.gameOverPanel.toggleButton.y + self.gameOverPanel.toggleButton.height then

            -- Use standard animation
            self:activateButtonAnimation(self.gameOverPanel.toggleButton)

            -- Hide game over panel to show battlefield
            self.gameOverPanel.visible = false

            -- Automatically position the mouse cursor over the return button
            if self.gameOverPanel.returnButton then
                love.mouse.setPosition(
                    self.gameOverPanel.returnButton.x + self.gameOverPanel.returnButton.width/2,
                    self.gameOverPanel.returnButton.y + self.gameOverPanel.returnButton.height/2
                )
            end

            return true
        end

        -- Return to results button (similar pattern)
        if not self.gameOverPanel.visible and
           mouseX >= self.gameOverPanel.returnButton.x and
           mouseX <= self.gameOverPanel.returnButton.x + self.gameOverPanel.returnButton.width and
           mouseY >= self.gameOverPanel.returnButton.y and
           mouseY <= self.gameOverPanel.returnButton.y + self.gameOverPanel.returnButton.height then

            -- Use standard animation
            self:activateButtonAnimation(self.gameOverPanel.returnButton)

            -- Show game over panel again
            self.gameOverPanel.visible = true

            -- Automatically position the mouse cursor over the main menu button
            if self.gameOverPanel.button then
                love.mouse.setPosition(
                    self.gameOverPanel.button.x + self.gameOverPanel.button.width/2,
                    self.gameOverPanel.button.y + self.gameOverPanel.button.height/2
                )
            end
            
            return true
        end
    end

    if not inGameOver and self:handleOnlineReactionButtonClick(mouseX, mouseY) then
        return true
    end

    -- Check for phase button clicks if applicable
    if not inGameOver and self:handlePhaseButtonClick(mouseX, mouseY) then
        return true
    end

    -- Check for game log panel clicks
    if not inGameOver and self:handleGameLogPanelClick(mouseX, mouseY) then
        return true
    end

    -- Check if the click is on a supply panel unit
    if not inGameOver and self:handleClickOnSupplyPanel(mouseX, mouseY) then
        return true
    end

    return false
end

function uiClass:handlePhaseButtonClick(mouseX, mouseY)
    local gameRuler = self.gameRuler
    if not gameRuler then
        return false
    end

    if self.phaseButton and
       mouseX >= self.phaseButton.x and mouseX <= self.phaseButton.x + self.phaseButton.width and
       mouseY >= self.phaseButton.y and mouseY <= self.phaseButton.y + self.phaseButton.height then

        self:activateButtonAnimation(self.phaseButton)

        -- Handle "Back to Menu" button in AI vs AI mode
        if self.phaseButton.action == "backToMenu" then
            local ConfirmDialog = require('confirmDialog')
            ConfirmDialog.show(
                "Return to main menu?",
                function()
                    -- Confirmed - go back to main menu
                    if self.stateMachineRef and self.stateMachineRef.changeState then
                        self.stateMachineRef.changeState("mainMenu")
                    end
                end,
                function()
                    -- Canceled - continue watching
                end
            )
            return true
        end

        if self.phaseButton.actionType and self.phaseButton.actionType ~= "" then
            if self.phaseButton.actionType == "placeAllNeutralBuildings" then  -- **NEW: Handle the new action**
                return self:handlePlaceAllNeutralBuildingsAction()
            elseif self.phaseButton.actionType == "placeNeutralBuilding" then
                return self:handlePlaceNeutralBuildingAction()
            elseif self.phaseButton.actionType == "placeCommandHub" then
                return true
            elseif self.phaseButton.actionType == "ReturnToMainMenu" then
                --print("Returning to main menu...")
            else
                return self:handlePhaseAdvanceAction()
            end
        end
    end

    return false
end

function uiClass:lockPhaseButtonAfterPress()
    self.phaseButtonLock.active = true
    if self.gameRuler then
        self.phaseButtonLock.phase = self.gameRuler.currentPhase
        self.phaseButtonLock.turnPhase = self.gameRuler.currentTurnPhase
    else
        self.phaseButtonLock.phase = nil
        self.phaseButtonLock.turnPhase = nil
    end
    self.phaseButton = nil
end

function uiClass:activateButtonAnimation(button)
    self.buttonAnimation.active = true
    self.buttonAnimation.timer = 0
    self.buttonAnimation.x = button.x
    self.buttonAnimation.y = button.y
    self.buttonAnimation.width = button.width
    self.buttonAnimation.height = button.height
end

function uiClass:handlePlaceNeutralBuildingAction()
    local validRow, validCol = self:getRandomNeutralBuildingPosition()
    if validRow and validCol then
        local success, message = self.gameRuler:performAction("placeNeutralBuilding", {
            row = validRow,
            col = validCol
        })
    end
    return true
end

function uiClass:handleGameLogPanelClick(mouseX, mouseY)
    if not self.gameLogPanel then
        return false
    end

    if self.gameRuler and self.gameRuler.currentPhase == "gameOver" and self.gameOverPanel and self.gameOverPanel.visible then
        return false
    end
    
    -- Block game log panel clicks in AI vs AI mode
    if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI then
        return false
    end

    -- Check if click is within game log panel bounds
    if mouseX >= self.gameLogPanel.x and mouseX <= self.gameLogPanel.x + self.gameLogPanel.width and
       mouseY >= self.gameLogPanel.y and mouseY <= self.gameLogPanel.y + self.gameLogPanel.height then

        -- Play click sound like phase button
        self:playButtonBeep()

        -- Set game log panel as active UI element for keyboard navigation
        for i, element in ipairs(self.uiElements) do
            if element.name == "gameLogPanel" then
                self.currentUIElementIndex = i
                self.activeUIElement = element
                self.navigationMode = "ui"
                self.uIkeyboardNavigationActive = true
                HOVER_INDICATOR_STATE.IS_HIDDEN = true
                self:syncKeyboardAndMouseFocus()
                break
            end
        end
        
        -- Show the full game log viewer window
        if self.gameRuler then
            GameLogViewer.show(self.gameRuler)
        end
        return true
    end
    
    return false
end

function uiClass:handlePlaceAllNeutralBuildingsAction()
    -- Call the gameRuler to place all Rocks
    local success, message = self.gameRuler:performAction("placeAllNeutralBuildings", {})
    if success then
        self:updateSupplyFromGameRuler()
    end
    return true
end

function uiClass:handlePhaseAdvanceAction()
    if not self.phaseButton or not self.phaseButton.actionType or self.phaseButton.actionType == "" then
        return false
    end
    local success, message = self.gameRuler:performAction(self.phaseButton.actionType, {})

    if success == true then
        self:updateSupplyFromGameRuler()
    end

    if success ~= false then
        self:lockPhaseButtonAfterPress()
        return true
    end

    self._lastSetContentMemoKey = contentMemoKey
    self._lastSetContentTheme = activeTheme

    return true
end

function uiClass:handleClickOnSupplyPanel(x, y)
    self:clearHoveredInfo()

    -- Check if clicked on any cell in the supply panels
    for _, unitPos in ipairs(self.unitPositions) do
        if x >= unitPos.x and x <= unitPos.x + unitPos.size and y >= unitPos.y and y <= unitPos.y + unitPos.size then
            local panelFaction = self:getSupplyFactionForPanel(unitPos.panelPlayer)
            local actualPlayer = self:getSupplyOwnerForPanel(unitPos.panelPlayer)

            -- NEW: Block clicks on other player's supply panel during relevant phases
            if self.gameRuler then
                -- Check if we're in a phase where player interaction matters
                local inRelevantPhase = (
                    (self.gameRuler.currentPhase == "deploy1_units" or 
                     self.gameRuler.currentPhase == "deploy2_units") or
                    (self.gameRuler.currentPhase == "turn" and 
                     self.gameRuler.currentTurnPhase == "actions")  -- CHANGED: from "supply" to "actions"
                )

                -- If in relevant phase and this is not the current player's panel, block the click
                if inRelevantPhase and actualPlayer ~= self.gameRuler.currentPlayer then
                    return true -- Block the click by returning true
                end
            end

            -- If this is an empty cell, just show empty info and return
            if unitPos.isEmpty then
                -- Show empty cell info in panel
                self.infoPanel.title = "EMPTY SLOT"
                local emptyInfo = {
                    status = "Empty Supply Slot",
                    panel = unitPos.panelPlayer == 1 and "Left Panel" or "Right Panel"
                }
                self:setContent(emptyInfo, self.playerThemes[panelFaction])
                return true
            end

            -- Always show unit information in the info panel, regardless of phase
            local unitInfo = self:createUnitInfoFromUnit(unitPos.unit, panelFaction)
            self.infoPanel.title = string.upper(unitPos.unit.name or "Unit")
            self:setContent(unitInfo, self.playerThemes[panelFaction])

            -- Only set selection state and highlight units during relevant phases
            if self.gameRuler and (
               (self.gameRuler.currentPhase == "deploy1_units" or 
                self.gameRuler.currentPhase == "deploy2_units") or
               (self.gameRuler.currentPhase == "turn" and 
                self.gameRuler.currentTurnPhase == "actions")) then  -- CHANGED: from "supply" to "actions"

                -- If we're in a deployment phase and the unit belongs to the current player
                if self.gameRuler.currentPhase == "deploy1_units" or self.gameRuler.currentPhase == "deploy2_units" then
                    if actualPlayer == self.gameRuler.currentPlayer then
                        -- BUG FIX: Check if initial deployment is already complete
                        if self.gameRuler:isInitialDeploymentComplete() then
                            -- Deployment already complete, don't allow further unit selection
                            return true
                        end
                        
                        -- **UPDATED: Only store selected unit info for deployment phases, not actions phase**
                        self.selectedUnit = unitPos.unit
                        self.selectedUnitPlayer = panelFaction
                        self.selectedUnitOwner = actualPlayer
                        self.selectedUnitIndex = unitPos.index
                        self.selectedUnitCoordOnPanel = { x = unitPos.x, y = unitPos.y }

                        self.gameRuler:performAction("selectSupplyUnit", {
                            unitIndex = unitPos.index
                        })
                    else
                        self.gameRuler.currentGrid:clearForcedHighlightedCells()
                        self.gameRuler.initialDeployment.selectedUnitIndex = nil
                    end
                elseif self.gameRuler.currentPhase == "turn" and self.gameRuler.currentTurnPhase == "actions" and actualPlayer == self.gameRuler.currentPlayer then

                    if self.gameRuler.currentActionPreview then
                        self.gameRuler.currentActionPreview = nil
                    end
                    if self.gameRuler.currentGrid then
                        self.gameRuler.currentGrid:clearForcedHighlightedCells()
                        self.gameRuler.currentGrid:clearSelectedGridUnit()
                    end

                    if self.gameRuler.hasDeployedThisTurn then
                        return true
                    end

                    -- Call the selectSupplyUnit function for actions phase
                    local success, message = self.gameRuler:performAction("selectSupplyUnit", {
                        unitIndex = unitPos.index
                    })

                    if success then
                        -- Set the selection to remain visible
                        self.selectedUnit = unitPos.unit
                        self.selectedUnitPlayer = panelFaction
                        self.selectedUnitOwner = actualPlayer
                        self.selectedUnitIndex = unitPos.index
                        self.selectedUnitCoordOnPanel = { x = unitPos.x, y = unitPos.y }

                        -- If using keyboard navigation, maintain the active element
                        if self.uIkeyboardNavigationActive then
                            for i, element in ipairs(self.uiElements) do
                                if element.x == unitPos.x and element.y == unitPos.y then
                                    self.currentUIElementIndex = i
                                    self.activeUIElement = element
                                    break
                                end
                            end
                        end
                    else
                        self.selectedUnit = nil
                        self.selectedUnitPlayer = nil
                        self.selectedUnitOwner = nil
                        self.selectedUnitCoordOnPanel = nil
                    end
                end
            end

            return true
        end
    end
    return false
end

-- Add this to uiClass.lua
function uiClass:getSelectedUnitInfo()
    return {
        unit = self.selectedUnit,
        index = self.selectedUnitIndex,
        player = self.selectedUnitOwner or self.selectedUnitPlayer,
        displayFaction = self.selectedUnitPlayer
    }
end

function uiClass:createUnitInfoFromUnit(unit, player)
    if not unit then return {} end

    local unitInfo = {
        unitObject = unit,
        name = unit.name or "Unknown",
        type = unit.type or "Unit",
        player = player,
        hp = unit.currentHp or unit.startingHp or "N/A",
        -- Use centralized functions to get unit stats with debug printing
        move = unitsInfo:getUnitMoveRange(unit, "UI_CLASS_UNIT_INFO"),
        atkRange = unitsInfo:getUnitAttackRange(unit, "UI_CLASS_UNIT_INFO"),
        atkDamage = unitsInfo:getUnitAttackDamage(unit, "UI_CLASS_UNIT_INFO"),
        fly = unitsInfo:getUnitFlyStatus(unit, "UI_CLASS_UNIT_INFO") and "Yes" or "No",
        descriptions = unit.descriptions,
        specialAbilitiesDescriptions = unit.specialAbilitiesDescriptions
    }

    -- Add HP as current/max if available
    if unit.currentHp and unit.startingHp then
        unitInfo.hp = unit.currentHp .. "/" .. unit.startingHp
    end

    return unitInfo
end

--------------------------------------------------
-- DRAWING METHODS
--------------------------------------------------

function uiClass:drawStandardPanel(x, y, width, height, title, content, isActive, theme)
    -- Neutral panel colors matching your existing aesthetic
    local defaultColors = {
        background = {46/255, 38/255, 32/255, 0.9},   -- Dark brown background
        border = {108/255, 88/255, 66/255, 1},        -- Medium brown border
        text = {203/255, 183/255, 158/255, 0.95},     -- Light tan text
        highlight = {79/255, 62/255, 46/255, 0.9},    -- Highlight brown
    }

    local colors
    if theme then
        colors = {
            background = theme.panel or defaultColors.background,
            border = theme.border or defaultColors.border,
            text = theme.text or defaultColors.text,
            highlight = theme.highlight or defaultColors.highlight
        }
    else
        colors = defaultColors
    end

    -- Draw panel background
    love.graphics.setColor(colors.background)
    love.graphics.rectangle("fill", x, y, width, height)

    -- Draw panel border - brighten if active
    if isActive then
        -- Brighter, more noticeable border for active panel
        love.graphics.setColor(203/255, 183/255, 158/255, 0.9)
        love.graphics.setLineWidth(3)
    else
        -- Normal border
        love.graphics.setColor(colors.border)
        love.graphics.setLineWidth(2)
    end
    love.graphics.rectangle("line", x, y, width, height)
    love.graphics.setLineWidth(1)

    -- Draw inner border detail (tech-style)
    love.graphics.setColor(colors.highlight)
    love.graphics.rectangle("line", x + 3, y + 3, width - 6, height - 6)

    -- Draw horizontal line separator
    love.graphics.setColor(colors.border)
    love.graphics.line(x + 10, y + 30, x + width - 10, y + 30)

    -- Draw title (brighten if active)
    -- Save current font and set title font
    local defaultFont = love.graphics.getFont()
    local titleFont = getMonogramFont(SETTINGS.FONT.TITLE_SIZE)
    love.graphics.setFont(titleFont)

    if isActive then
        love.graphics.setColor(255/255, 240/255, 220/255, 1.0)
    else
        love.graphics.setColor(colors.text)
    end
    love.graphics.printf(title, x, y + 6, width, "center")

    -- Restore original font
    love.graphics.setFont(defaultFont)

    -- Draw content if provided (function or text)
    if type(content) == "function" then
        -- Execute the content drawing function
        content(x, y, width, height, colors)
    elseif type(content) == "string" then
        -- Draw simple text content
        love.graphics.setColor(colors.text)
        love.graphics.printf(content, x, y + 40, width, "center")
    end
end

function uiClass:drawTurnCounter(currentTurn, currentPlayer)
    local panelX = SETTINGS.DISPLAY.WIDTH - 250
    local panelY = 320
    local panelWidth = 100
    local panelHeight = 80

    -- Content drawing function
    local contentDrawFunc = function(x, y, width, height, colors)
        -- Format number with leading zero
        local turnDisplay = string.format("%02d", currentTurn or 0)

        -- Get width of text for centering with large font
        local largeFont = getDefaultFont(SETTINGS.FONT.BIG_SIZE)
        local textWidth = largeFont:getWidth(turnDisplay)
        local textHeight = largeFont:getHeight()

        -- Save current font
        local defaultFont = love.graphics.getFont()

        -- Calculate vertical center position (panel content starts at y+40)
        local contentArea = height - 40  -- Height of content area
        local verticalPos = y + 32 + (contentArea - textHeight) / 2

        -- Apply zoom effect if active
        local scale = self.turnZoom.isActive and self.turnZoom.scale or 1.0
        local colorIntensity = self.turnZoom.isActive and self.turnZoom.colorIntensity or 1.0
        
        -- Calculate scaled dimensions and position
        local scaledWidth = textWidth * scale
        local scaledHeight = textHeight * scale
        local scaledX = x + (width - scaledWidth) / 2
        local scaledY = verticalPos + (textHeight - scaledHeight) / 2

        -- Use the larger font directly
        love.graphics.setFont(largeFont)
        
        -- Apply color with intensity (gets whiter at max zoom)
        local baseR, baseG, baseB = 255/255, 240/255, 220/255
        local r = math.min(1.0, baseR * colorIntensity)
        local g = math.min(1.0, baseG * colorIntensity)
        local b = math.min(1.0, baseB * colorIntensity)
        love.graphics.setColor(r, g, b, 0.95)
        
        -- Apply scaling
        love.graphics.push()
        love.graphics.translate(scaledX + scaledWidth/2, scaledY + scaledHeight/2)
        love.graphics.scale(scale, scale)
        love.graphics.print(turnDisplay, -textWidth/2, -textHeight/2)
        love.graphics.pop()

        -- Restore original font
        love.graphics.setFont(defaultFont)
    end

    self:drawStandardPanel(panelX, panelY, panelWidth, panelHeight, "TURN", contentDrawFunc)
end

function uiClass:drawSurrenderPanel()
    local panelX = SETTINGS.DISPLAY.WIDTH - 130     -- Position
    local panelY = 320                              -- Position
    local panelWidth = 100                          -- Width
    local panelHeight = 80                          -- Height

    -- Content drawing function to display the surrender button
    local contentDrawFunc = function(x, y, width, height, colors)
        self.surrenderButton = self.surrenderButton or self:createDefaultSurrenderButton()
        -- Only show surrender button during turn/actions phase
        if self.gameRuler and self.gameRuler.currentPhase == "turn" and 
           self.gameRuler.currentTurnPhase == "actions" and
           (GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL or GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET or
           (GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and self.gameRuler.currentPlayer ~= GAME.CURRENT.AI_PLAYER_NUMBER)) then

            -- Calculate button position within panel
            local padding = 15
            local buttonWidth = width - padding * 2
            local buttonHeight = 28
            local buttonY = y + height - buttonHeight - padding
            local buttonX = x + padding

            -- Update button colors based on local surrendering faction in online mode.
            local surrenderFaction = self:resolveSurrenderFactionId()
            local useRedTheme = (surrenderFaction == 2)
            
            if useRedTheme then
                -- Red theme for player 2
                self.surrenderButton.normalColor = {0.8, 0.2, 0.2, 0.9}
                self.surrenderButton.hoverColor = {0.9, 0.3, 0.3, 0.95}
                self.surrenderButton.pressedColor = {0.6, 0.15, 0.15, 0.9}
            else
                -- Blue theme for player 1
                self.surrenderButton.normalColor = {0.2, 0.4, 0.8, 0.9}
                self.surrenderButton.hoverColor = {0.3, 0.5, 0.9, 0.95}
                self.surrenderButton.pressedColor = {0.15, 0.3, 0.6, 0.9}
            end
            
            -- Update currentColor to match the normal color if not hovering
            -- Check if currentColor matches hoverColor by comparing individual components
            local isCurrentlyHovering = (
                self.surrenderButton.currentColor[1] == self.surrenderButton.hoverColor[1] and
                self.surrenderButton.currentColor[2] == self.surrenderButton.hoverColor[2] and
                self.surrenderButton.currentColor[3] == self.surrenderButton.hoverColor[3] and
                self.surrenderButton.currentColor[4] == self.surrenderButton.hoverColor[4]
            )
            if not isCurrentlyHovering then
                self.surrenderButton.currentColor = self.surrenderButton.normalColor
            end

            -- Update button properties
            self.surrenderButton.x = buttonX
            self.surrenderButton.y = buttonY
            self.surrenderButton.width = buttonWidth
            self.surrenderButton.height = buttonHeight

            -- Draw the button background
            love.graphics.setColor(self.surrenderButton.currentColor)
            love.graphics.rectangle("fill", buttonX, buttonY, buttonWidth, buttonHeight, 5)

            -- Button border - whitish border for hover/focus state
            local isMouseHovered = (
                self.surrenderButton.currentColor[1] == self.surrenderButton.hoverColor[1] and
                self.surrenderButton.currentColor[2] == self.surrenderButton.hoverColor[2] and
                self.surrenderButton.currentColor[3] == self.surrenderButton.hoverColor[3] and
                self.surrenderButton.currentColor[4] == self.surrenderButton.hoverColor[4]
            )
            local isKeyboardFocused = (self.uIkeyboardNavigationActive and self.activeUIElement and 
                                      self.activeUIElement.name == "surrenderButton")

            if isMouseHovered or isKeyboardFocused then
                love.graphics.setColor(255/255, 240/255, 220/255, 0.8)  -- Whitish border for both mouse and keyboard
                love.graphics.setLineWidth(2.5)
            else
                if useRedTheme then
                    love.graphics.setColor(0.9, 0.3, 0.3, 0.8) -- Red border for player 2
                else
                    love.graphics.setColor(0.3, 0.5, 0.9, 0.8) -- Blue border for player 1
                end
                love.graphics.setLineWidth(1.0) -- Thinner line width
            end
            love.graphics.rectangle("line", buttonX, buttonY, buttonWidth, buttonHeight, 5)
            love.graphics.setLineWidth(1) -- Reset line width

            -- Inner accent line - dynamic color based on theme
            if useRedTheme then
                love.graphics.setColor(1, 0.8, 0.8, 0.2) -- Reddish glow for player 2
            else
                love.graphics.setColor(0.8, 0.9, 1, 0.2) -- Bluish glow for player 1
            end
            love.graphics.rectangle("line", buttonX + 2, buttonY + 2, buttonWidth - 4, buttonHeight - 4, 3)

            -- Button text
            -- Save current font and set button font
            local defaultFont = love.graphics.getFont()
            local buttonFont = getMonogramFont(SETTINGS.FONT.TITLE_SIZE)
            love.graphics.setFont(buttonFont)

            love.graphics.setColor(1, 0.9, 0.9, 0.95) -- Slightly lighter text for contrast
            love.graphics.printf(self.surrenderButton.text, buttonX + 4, buttonY + (buttonHeight - buttonFont:getHeight())/2, buttonWidth, "center")

            -- Restore original font
            love.graphics.setFont(defaultFont)
        else
            -- If not in correct phase, show a message
            -- Save current font and set info font
            local defaultFont = love.graphics.getFont()
            local infoFont = getMonogramFont(SETTINGS.FONT.DEFAULT_SIZE)
            love.graphics.setFont(infoFont)

            love.graphics.setColor(colors.text[1], colors.text[2], colors.text[3], 0.7)
            love.graphics.printf("Not\nAvailable", x + 10, y + 36, width - 20, "center")

            -- Restore original font
            love.graphics.setFont(defaultFont)
        end
    end

    -- Use the standard panel function
    self:drawStandardPanel(panelX, panelY, panelWidth, panelHeight, "CALL", contentDrawFunc)
end

function uiClass:drawScenarioControlPanel()
    if not self:updateScenarioControlLayout() then
        return
    end

    local panel = self.scenarioControlPanel
    local scenarioCode = self:getScenarioCode()
    local attempts = self:getScenarioAttemptsCount()
    local elapsedClock = self:formatElapsedClock(self:getScenarioElapsedSeconds())

    local function drawScenarioButton(button, buttonName)
        local isKeyboardFocused = self.uIkeyboardNavigationActive
            and self.activeUIElement
            and self.activeUIElement.name == buttonName
        local isMouseHovered = (
            button.currentColor[1] == button.hoverColor[1]
            and button.currentColor[2] == button.hoverColor[2]
            and button.currentColor[3] == button.hoverColor[3]
            and button.currentColor[4] == button.hoverColor[4]
        )

        love.graphics.setColor(button.currentColor)
        love.graphics.rectangle("fill", button.x, button.y, button.width, button.height, 6)

        if isMouseHovered or isKeyboardFocused then
            love.graphics.setColor(255/255, 240/255, 220/255, 0.8)
            love.graphics.setLineWidth(2.5)
        else
            love.graphics.setColor(button.normalColor[1], button.normalColor[2], button.normalColor[3], 0.9)
            love.graphics.setLineWidth(1.4)
        end
        love.graphics.rectangle("line", button.x, button.y, button.width, button.height, 6)
        love.graphics.setLineWidth(1)

        if isMouseHovered or isKeyboardFocused then
            love.graphics.setColor(1, 1, 1, 0.2)
            love.graphics.rectangle("line", button.x + 2, button.y + 2, button.width - 4, button.height - 4, 4)
        end

        local defaultFont = love.graphics.getFont()
        local buttonFont = getMonogramFont(SETTINGS.FONT.TITLE_SIZE)
        love.graphics.setFont(buttonFont)
        love.graphics.setColor(1, 1, 1, 0.95)
        love.graphics.printf(button.text or "", button.x, button.y + (button.height - buttonFont:getHeight()) / 2, button.width, "center")
        love.graphics.setFont(defaultFont)
    end

    local contentDrawFunc = function(x, y, width, height, colors)
        local defaultFont = love.graphics.getFont()
        local labelFont = getMonogramFont(SETTINGS.FONT.TITLE_SIZE)
        local valueFont = getMonogramFont(SETTINGS.FONT.DEFAULT_SIZE)
        local rows = {
            { label = "CODE", value = tostring(scenarioCode) },
            { label = "ATTEMPTS", value = tostring(attempts) },
            { label = "TIMER", value = elapsedClock }
        }
        local rowX = x + 12
        local rowW = width - 24
        local rowH = 42
        local rowGap = 10
        local startY = y + 44

        for i, row in ipairs(rows) do
            local rowY = startY + (i - 1) * (rowH + rowGap)

            love.graphics.setColor(0.12, 0.1, 0.08, 0.55)
            love.graphics.rectangle("fill", rowX, rowY, rowW, rowH, 6)
            love.graphics.setColor(colors.highlight[1], colors.highlight[2], colors.highlight[3], 0.85)
            love.graphics.rectangle("line", rowX + 1, rowY + 1, rowW - 2, rowH - 2, 5)

            love.graphics.setFont(labelFont)
            love.graphics.setColor(colors.text[1], colors.text[2], colors.text[3], 0.9)
            love.graphics.print(row.label, rowX + 10, rowY + 6)

            love.graphics.setFont(valueFont)
            love.graphics.setColor(1, 1, 1, 0.96)
            love.graphics.printf(row.value, rowX + 8, rowY + 20, rowW - 16, "right")
        end

        drawScenarioButton(self.scenarioBackButton, "scenarioBackButton")
        drawScenarioButton(self.scenarioRetryButton, "scenarioRetryButton")

        love.graphics.setFont(defaultFont)
    end

    self:drawStandardPanel(panel.x, panel.y, panel.width, panel.height, "SCENARIO", contentDrawFunc)
end

function uiClass:drawScenarioObjectivePanel()
    if not self:updateScenarioObjectiveLayout() then
        return
    end

    local panel = self.scenarioObjectivePanel
    local sprite = self:ensureScenarioObjectiveCommandantSprite()
    local objectiveText = self:getScenarioWinningConditionsText()

    local bubbleColor = {240/255, 248/255, 255/255, 0.95}
    local bubbleOutline = {60/255, 80/255, 120/255, 1.0}
    local textColor = {40/255, 40/255, 60/255, 1.0}

    local spriteScaleX = 0.2
    local spriteScaleY = 0.2
    local spriteX = panel.x + 48
    local spriteY = panel.y + panel.height - 98
    local scaledSpriteW = 0
    local scaledSpriteH = 0

    local referenceSpriteScale = 0.2
    local targetSpriteW = 112
    local targetSpriteH = 90
    if not self.bluRadioSprite then
        local ok, img = pcall(love.graphics.newImage, "assets/sprites/Blu_Radio.png")
        if ok and img then
            self.bluRadioSprite = img
        end
    end
    if self.bluRadioSprite then
        targetSpriteW = self.bluRadioSprite:getWidth() * referenceSpriteScale
        targetSpriteH = self.bluRadioSprite:getHeight() * referenceSpriteScale
    end

    if sprite then
        spriteScaleX = targetSpriteW / sprite:getWidth()
        spriteScaleY = targetSpriteH / sprite:getHeight()
        scaledSpriteW = targetSpriteW
        scaledSpriteH = targetSpriteH
        spriteX = panel.x + (panel.width - scaledSpriteW) / 2
        local spriteBottomPadding = 6
        local spriteDropOffset = 24
        spriteY = panel.y + panel.height - scaledSpriteH - spriteBottomPadding + spriteDropOffset
    end

    local bubbleYOffset = -24
    local bubbleX = panel.x + 15
    local bubbleY = panel.y + 15 + bubbleYOffset
    local bubbleW = panel.width - 30
    local bubbleH = (sprite and (spriteY - bubbleY - 11)) or (panel.height - 30)
    if bubbleH < 92 then
        bubbleH = 92
    end

    love.graphics.setColor(bubbleColor)
    love.graphics.rectangle("fill", bubbleX, bubbleY, bubbleW, bubbleH, 15)

    love.graphics.setColor(bubbleOutline)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", bubbleX, bubbleY, bubbleW, bubbleH, 15)

    local tailCenterX = bubbleX + bubbleW / 2 + self.bubbleTriangle.offsetX
    local tailCenterY = bubbleY + bubbleH + self.bubbleTriangle.offsetY
    love.graphics.push()
    love.graphics.translate(tailCenterX, tailCenterY)
    love.graphics.scale(self.bubbleTriangle.scale, self.bubbleTriangle.scale)
    love.graphics.translate(-tailCenterX, -tailCenterY)
    local tailPoints = {
        tailCenterX - 12, bubbleY + bubbleH,
        tailCenterX, tailCenterY + 15,
        tailCenterX + 12, bubbleY + bubbleH
    }
    love.graphics.polygon("fill", tailPoints)
    love.graphics.polygon("line", tailPoints)
    love.graphics.pop()

    local defaultFont = love.graphics.getFont()
    local bubbleTextFont = getMonogramFont(SETTINGS.FONT.DEFAULT_SIZE)
    love.graphics.setFont(bubbleTextFont)
    love.graphics.setColor(textColor)
    love.graphics.printf(objectiveText, bubbleX + 12, bubbleY + 8, bubbleW - 24, "left")
    love.graphics.setFont(defaultFont)

    if sprite then
        love.graphics.setColor(1, 1, 1, 1)
        -- Flip horizontally so the Commandant faces inward.
        love.graphics.draw(sprite, spriteX + scaledSpriteW, spriteY, 0, -spriteScaleX, spriteScaleY)
    end

    love.graphics.setLineWidth(1)
end

function uiClass:drawLogPanel(gameRuler)
    local panelX = 30                          -- Position on left side
    local codexButtonX = 30
    local codexButtonY = 320
    local codexButtonWidth = 220
    local codexButtonHeight = 34
    local panelY = 362
    local panelWidth = 220                     -- Width matches supply panels
    local panelHeight = 92

    self.unitCodexButton = self.unitCodexButton or {}
    self.unitCodexButton.x = codexButtonX
    self.unitCodexButton.y = codexButtonY
    self.unitCodexButton.width = codexButtonWidth
    self.unitCodexButton.height = codexButtonHeight

    -- Initialize game log panel button if it doesn't exist
    if not self.gameLogPanel then
        self.gameLogPanel = {
            x = panelX,
            y = panelY,
            width = panelWidth,
            height = panelHeight
        }
    end

    -- Update panel position and size
    self.gameLogPanel.x = panelX
    self.gameLogPanel.y = panelY
    self.gameLogPanel.width = panelWidth
    self.gameLogPanel.height = panelHeight

    -- Check if panel is hovered or focused
    local mouseX, mouseY = love.mouse.getPosition()
    local transformedX, transformedY = (mouseX - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE, (mouseY - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
    
    local isMouseHovered = transformedX >= panelX and transformedX <= panelX + panelWidth and
                          transformedY >= panelY and transformedY <= panelY + panelHeight

    if self.gameRuler and self.gameRuler.currentPhase == "gameOver" and self.gameOverPanel and self.gameOverPanel.visible then
        isMouseHovered = false
    end
    
    -- Block game log panel hover in AI vs AI mode
    if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI then
        isMouseHovered = false
    end
    
    -- If the game log modal is active, suppress hover/focus visuals and sounds on the underlying panel
    local confirmDialogActive = ConfirmDialog and ConfirmDialog.isActive and ConfirmDialog.isActive()
    local modalActive = (GameLogViewer and GameLogViewer.isActive and GameLogViewer.isActive()) or confirmDialogActive or self.overlayInputBlocked == true
    if modalActive then
        isMouseHovered = false
        self:clearGameLogPanelHover()
    end
    
    -- Override mouse hover if force no hover flag is set
    if self.gameLogPanelForceNoHover then
        isMouseHovered = false
        -- Check if mouse has moved since we disabled hover
        if self.gameLogPanelDisabledMouseX and self.gameLogPanelDisabledMouseY then
            local currentMouseX, currentMouseY = love.mouse.getPosition()
            if currentMouseX ~= self.gameLogPanelDisabledMouseX or currentMouseY ~= self.gameLogPanelDisabledMouseY then
                -- Mouse has moved, re-enable hover detection
                self.gameLogPanelForceNoHover = false
                self.gameLogPanelDisabledMouseX = nil
                self.gameLogPanelDisabledMouseY = nil
            end
        else
            -- Clear the flag after one frame if no position was stored
            self.gameLogPanelForceNoHover = false
        end
    end
    
    local isKeyboardFocused = (self.uIkeyboardNavigationActive and self.activeUIElement and 
                              self.activeUIElement.name == "gameLogPanel" and self.navigationMode == "ui")
    if modalActive then
        isKeyboardFocused = false
    end
    
    -- Clear hover state if neither mouse nor keyboard is focusing on the panel
    if not isMouseHovered and not isKeyboardFocused then
        self.gameLogPanelPreviousHover = false
    end

    -- Handle hover sound (similar to other UI elements)
    if not self.gameLogPanelPreviousHover then
        self.gameLogPanelPreviousHover = false
    end
    
    if (isMouseHovered or isKeyboardFocused) and not self.gameLogPanelPreviousHover then
        -- Play hover sound when first hovering/focusing
        if not modalActive then
            self:playButtonBeep()
        end
        
        -- When mouse hovers over game log panel, set it as active UI element for keyboard navigation
        if not modalActive and isMouseHovered and not isKeyboardFocused then
            for i, element in ipairs(self.uiElements) do
                if element.name == "gameLogPanel" then
                    self.currentUIElementIndex = i
                    self.activeUIElement = element
                    self.navigationMode = "ui"
                    self.uIkeyboardNavigationActive = true
                    HOVER_INDICATOR_STATE.IS_HIDDEN = true
                    break
                end
            end
        end
    end
    
    self.gameLogPanelPreviousHover = (isMouseHovered or isKeyboardFocused)

    -- Content drawing function that displays the log entries
    local contentDrawFunc = function(x, y, width, height, colors)
        -- Save current font and set log font
        local defaultFont = love.graphics.getFont()
        local logFont = getMonogramFont(SETTINGS.FONT.INFO_SIZE)
        love.graphics.setFont(logFont)
        
        -- Draw log entries
        love.graphics.setColor(colors.text)

        if #gameRuler.turnLog == 0 then
            -- If no entries yet
            love.graphics.printf("No actions yet", x + 10, y + 40, width - 20, "left")
        else
            -- Display only the first 3 log entries to match the reduced panel height
            local lineHeight = 18
            local maxEntriesToShow = 3
            local entriesToShow = math.min(#gameRuler.turnLog, maxEntriesToShow)
            local contentTopY = y + 40
            local contentBottomY = y + height - 14
            local blockHeight = entriesToShow * lineHeight
            local startY = math.floor(contentTopY + ((contentBottomY - contentTopY) - blockHeight) / 2)

            for i = 1, entriesToShow do
                if i == 1 then
                    love.graphics.setColor(255/255, 240/255, 220/255, 0.95)
                elseif i == 2 then
                    love.graphics.setColor(colors.text[1], colors.text[2], colors.text[3], 0.7)
                elseif i == 3 then
                    love.graphics.setColor(colors.text[1], colors.text[2], colors.text[3], 0.55)
                end

                love.graphics.printf(gameRuler.turnLog[i], x + 10, startY + (i-1) * lineHeight, width - 20, "left")
            end
        end
        
        -- Restore original font
        love.graphics.setFont(defaultFont)
    end

    -- Use the standard panel function
    self:drawStandardPanel(panelX, panelY, panelWidth, panelHeight, "GAME LOG", contentDrawFunc)

    -- Draw white border if hovered or keyboard focused (like phase button)
    if (isMouseHovered or isKeyboardFocused) and not modalActive then
        love.graphics.setColor(255/255, 240/255, 220/255, 0.8)  -- Whitish border like other UI elements
        love.graphics.setLineWidth(2.5)
        love.graphics.rectangle("line", panelX, panelY, panelWidth, panelHeight)  -- No rounded corners
        
        -- Inner accent line (subtle highlight for depth like phase button)
        love.graphics.setColor(1, 1, 1, 0.2)
        love.graphics.rectangle("line", panelX + 3, panelY + 3, panelWidth - 6, panelHeight - 6)  -- No rounded corners
        
        love.graphics.setLineWidth(1)
    end
end

function uiClass:drawUnitIcon(x, y, size, unit, player, isHovered, isFocused, isSelected)
    -- Draw card background first if available
    if self.cardTemplateImage then
        -- Apply color tinting based on player (match faction screen tints)
        if player == 1 then
            -- Team blue tint
            love.graphics.setColor(0.2, 0.4, 0.8, 0.8)
        elseif player == 2 then
            -- Team red tint
            love.graphics.setColor(0.8, 0.2, 0.2, 0.8)
        else
            -- Default white for neutral/unknown players
            love.graphics.setColor(1, 1, 1, 1)
        end
        
        -- Calculate scaling to fit the card to the icon size
        local cardWidth = self.cardTemplateImage:getWidth()
        local cardHeight = self.cardTemplateImage:getHeight()
        local cardScale = math.min(size / cardWidth, size / cardHeight)
        
        -- Generate random flipping based on position (deterministic per position)
        local flipType = randomGen.getFlipType(x, y)
        
        -- Calculate flip scales
        local scaleX = cardScale
        local scaleY = cardScale
        local offsetX = 0
        local offsetY = 0
        
        if flipType == 2 or flipType == 4 then  -- Horizontal flip
            scaleX = -cardScale
            offsetX = cardWidth * cardScale
        end
        if flipType == 3 or flipType == 4 then  -- Vertical flip
            scaleY = -cardScale
            offsetY = cardHeight * cardScale
        end
        
        -- Center the card background
        local cardX = x + (size - cardWidth * cardScale) / 2 + offsetX
        local cardY = y + (size - cardHeight * cardScale) / 2 + offsetY
        
        love.graphics.draw(self.cardTemplateImage, cardX, cardY, 0, scaleX, scaleY)
    end

    -- Try to get unit image from icons mapping
    -- Determine which faction the icon should represent
    local panelData = self:getSupplyPanelData(player)
    local iconFaction = panelData.factionId or player

    local unitImage = self:getUnitImage(unit, iconFaction)

    if unitImage then
        -- No color tinting needed - sprites already have correct faction colors
        love.graphics.setColor(1, 1, 1, 1)

        -- Calculate scaling to fit the icon size (slightly smaller to fit on card) with zoom
        local imageWidth = unitImage:getWidth()
        local imageHeight = unitImage:getHeight()
        local scale = math.min(size / imageWidth, size / imageHeight) * 0.8

        -- Center the image in the icon area
        local drawX = x + (size - imageWidth * scale) / 2
        local drawY = y + (size - imageHeight * scale) / 2

        -- Flip horizontally by using negative x scale and adjusting position
        local scaleX = -scale  -- Negative scale for horizontal flip
        local scaleY = scale   -- Normal scale for vertical
        local flipAdjustX = drawX + imageWidth * scale  -- Adjust position for flip

        love.graphics.draw(unitImage, flipAdjustX, drawY, 0, scaleX, scaleY)

        -- Draw border around the image
        --self:drawUnitIconBorder(x, y, size, player)
    end
end

function uiClass:getPlayerColor(player)
    if player == 1 then
        return {0.2, 0.6, 1.0}  -- Blue for player 1
    elseif player == 2 then
        return {1.0, 0.3, 0.2}  -- Red for player 2
    else
        return {0.7, 0.7, 0.7}  -- Gray for neutral
    end
end

function uiClass:getUnitImage(unit, factionOverride)
    if not unit or not unit.name then return nil end

    -- Get image path from centralized unitsInfo
    local unitInfo = unitsInfo.stats[unit.name]
    if not unitInfo then
        return nil
    end

    -- Choose the correct icon path based on supplied faction (defaults to unit.player)
    local faction = factionOverride or unit.player or 1
    local imagePath
    if faction == 2 and unitInfo.pathUiIconRed then
        imagePath = unitInfo.pathUiIconRed  -- Red faction (player 2)
    elseif unitInfo.pathUiIcon then
        imagePath = unitInfo.pathUiIcon     -- Blue faction (player 1) or default
    else
        return nil
    end

    -- Try to load the image (cache it for performance)
    if not self.unitImages then
        self.unitImages = {}
    end

    if not self.unitImages[imagePath] then
        local success, image = pcall(love.graphics.newImage, imagePath)
        if success then
            self.unitImages[imagePath] = image
        else
            self.unitImages[imagePath] = false  -- Cache the failure
        end
    end

    return self.unitImages[imagePath] or nil
end

function uiClass:getPlayerTintedColor(baseColor, player)
    local finalColor = {baseColor[1], baseColor[2], baseColor[3], 0.7}

    if player == 1 then
        finalColor = {
            baseColor[1] * 0.7,
            baseColor[2] * 0.7,
            baseColor[3] * 0.7 + 0.3,
            0.7
        }
    elseif player == 2 then
        finalColor = {
            baseColor[1] * 0.7 + 0.3,
            baseColor[2] * 0.7,
            baseColor[3] * 0.7,
            0.7
        }
    end

    return finalColor
end

function uiClass:drawUnitIconBorder(x, y, size, player)
    if player == 1 or player == 2 then
        love.graphics.setColor(0, 0, 0, 0.8)
    else
        love.graphics.setColor(0.6, 0.6, 0.6, 0.8)
    end
    love.graphics.rectangle("line", x, y, size, size, 5)
end

function uiClass:drawUnitIconText(x, y, size, text)
    love.graphics.setColor(1, 1, 1)
    local font = love.graphics.getFont()
    local textWidth = font:getWidth(text)
    local textHeight = font:getHeight()
    love.graphics.print(text, x + (size - textWidth) / 2, y + (size - textHeight) / 2)
end

function uiClass:drawInfoPanel()
    local panel = self.infoPanel
    local x, y, width, height = panel.x, panel.y + 54, panel.width, panel.height - 54

    -- Use the unit and player from the panel if available
    local unitToDisplay = panel.displayUnit or self.selectedUnit or self.hoveredUnit
    local unitPlayerToDisplay = panel.displayUnitPlayer or self.selectedUnitPlayer or self.hoveredUnitPlayer

    if unitToDisplay and unitToDisplay.name then
        panel.title = string.upper(unitToDisplay.name)
    end

    -- Use card-based drawing instead of standard panel
    self:drawInfoPanelWithCard(x, y, width, height, panel.title, unitToDisplay, unitPlayerToDisplay, panel.content)
end

function uiClass:drawInfoPanelWithCard(x, y, width, height, title, unitToDisplay, unitPlayerToDisplay, content)
    -- Load grass background sprite (cache it for performance)
    if not self.cardBackgroundGrassSprite then
        local success, image = pcall(love.graphics.newImage, "assets/sprites/CardBackgroundGrass.png")
        if success then
            self.cardBackgroundGrassSprite = image
        end
    end
    
    -- Load sky background sprite for flying units (cache it for performance)
    if not self.cardBackgroundSkySprite then
        local success, image = pcall(love.graphics.newImage, "assets/sprites/CardBackgroundSky.png")
        if success then
            self.cardBackgroundSkySprite = image
        end
    end

    -- Use the same card template as supply panel
    if not self.cardTemplateImage then
        return -- Fallback if card template not loaded
    end

    -- Calculate scaling to fit the card to the panel size
    local cardWidth = self.cardTemplateImage:getWidth()
    local cardHeight = self.cardTemplateImage:getHeight()
    local cardScale = math.min(width / cardWidth, height / cardHeight)
    
    -- Generate random flipping to match the supply panel orientation
    local seed
    if unitToDisplay and unitPlayerToDisplay then
        -- Try to find this unit's position in supply panel
        local supplyIndex = nil
        local playerSupply = (unitPlayerToDisplay == 1) and self.playerSupply1 or self.playerSupply2
        if playerSupply then
            for i, unit in ipairs(playerSupply) do
                if unit == unitToDisplay then
                    supplyIndex = i
                    break
                end
            end
        end
        
        if supplyIndex then
            -- Use supply index directly as seed for consistent flipping
            -- This ensures the same unit always has the same flip orientation
            seed = supplyIndex * 1000 + (unitPlayerToDisplay or 1) * 100
        else
            -- Fallback to unit name hash if not found in supply
            seed = 0
            if unitToDisplay.name then
                for i = 1, #unitToDisplay.name do
                    seed = seed + string.byte(unitToDisplay.name, i)
                end
            end
        end
    else
        -- For default content, use a consistent seed
        seed = 12345  -- Fixed seed for consistent default appearance
    end
    
    -- Use the hovered supply icon's flip type if available, otherwise default to no flip
    local flipType = self.hoveredSupplyFlipType or 1
    
    -- Calculate flip scales and positioning (same for both grass and card)
    local scaleX = cardScale
    local scaleY = cardScale
    local offsetX = 0
    local offsetY = 0
    
    if flipType == 2 or flipType == 4 then  -- Horizontal flip
        scaleX = -cardScale
        offsetX = cardWidth * cardScale
    end
    if flipType == 3 or flipType == 4 then  -- Vertical flip
        scaleY = -cardScale
        offsetY = cardHeight * cardScale
    end
    
    -- Calculate centered position for grass (no flipping)
    local grassX = x + (width - cardWidth * cardScale) / 2
    local grassY = y + (height - cardHeight * cardScale) / 2
    
    -- Calculate centered position for card (with flipping)
    local cardX = x + (width - cardWidth * cardScale) / 2 + offsetX
    local cardY = y + (height - cardHeight * cardScale) / 2 + offsetY
    
    -- Draw the background first (no flipping, normal orientation)
    -- Use sky background for flying units, grass background for ground units
    local backgroundSprite = self.cardBackgroundGrassSprite -- Default to grass
    if unitToDisplay and unitToDisplay.name then
        local isFlying = unitsInfo:getUnitFlyStatus(unitToDisplay, "DRAW_INFO_PANEL_BACKGROUND")
        if isFlying and self.cardBackgroundSkySprite then
            backgroundSprite = self.cardBackgroundSkySprite
        end
    end
    
    if backgroundSprite then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(backgroundSprite, grassX, grassY, 0, cardScale, cardScale)
    end

    -- Draw the card template background with flipping
    -- Apply color tinting based on player
    if unitPlayerToDisplay == 1 then
        -- Team blue tint (match faction screen)
        love.graphics.setColor(0.2, 0.4, 0.8, 0.8)
    elseif unitPlayerToDisplay == 2 then
        -- Team red tint (match faction screen)
        love.graphics.setColor(0.8, 0.2, 0.2, 0.8)
    else
        -- Default white for neutral/unknown players
        love.graphics.setColor(1, 1, 1, 1)
    end
    love.graphics.draw(self.cardTemplateImage, cardX, cardY, 0, scaleX, scaleY)

    -- Define text colors for card overlay
    local colors = {
        text = {203/255, 183/255, 158/255, 0.95},     -- Light tan text
        highlight = {255/255, 240/255, 220/255, 1.0}, -- Bright highlight
        secondary = {180/255, 160/255, 140/255, 0.9}  -- Secondary text
    }

    -- Draw content over the card
    if unitToDisplay then
        self:drawUnitInfoContent(x + 10, y + 30, width - 20, height - 40, unitToDisplay, unitPlayerToDisplay, content, colors)
    elseif content.status and content.status == "Empty Cell" then
        self:drawEmptyCellContent(x + 10, y + 30, width - 20, height - 40, content, colors)
    else
        self:drawDefaultInfoContent(x + 10, y + 30, width - 20, colors)
    end
    
    -- Draw title over the card (center-aligned)
    if title then
        love.graphics.setColor(0.3, 0.3, 0.3, 0.9)
        local font = love.graphics.getFont()
        love.graphics.printf(title, x, y + 14, width, "center")
    end
    
    -- Draw 3 speech bubbles under the name for HP, Movement, Attack
    if unitToDisplay then
        self:drawStatBubbles(x, y + 35, width, unitToDisplay, unitPlayerToDisplay, content)
    end

    if not (type(content) == "table" and content.disableGloss == true) then
        self:drawInfoCardGlossOverlay(x, y, width, height, content)
    end
end

function uiClass:drawStatBubbles(x, y, width, unit, player, content)
    -- Load HP icon (cache it for performance)
    if not self.hpIconSprite then
        local success, image = pcall(love.graphics.newImage, "assets/sprites/Icon_HP.png")
        if success then
            self.hpIconSprite = image
        end
    end
    
    -- Load fly icons (cache them for performance)
    if not self.flyIconSprite then
        local success, image = pcall(love.graphics.newImage, "assets/sprites/Icon_Fly.png")
        if success then
            self.flyIconSprite = image
        end
    end
    
    if not self.noFlyIconSprite then
        local success, image = pcall(love.graphics.newImage, "assets/sprites/Icon_NoFly.png")
        if success then
            self.noFlyIconSprite = image
        end
    end
    
    -- Load attack type icons (cache them for performance)
    if not self.rangedIconSprite then
        local success, image = pcall(love.graphics.newImage, "assets/sprites/Icon_Ranged.png")
        if success then
            self.rangedIconSprite = image
        end
    end
    
    if not self.meleeIconSprite then
        local success, image = pcall(love.graphics.newImage, "assets/sprites/Icon_Melee.png")
        if success then
            self.meleeIconSprite = image
        end
    end
    
    -- Get stat values
    local hpText = self:formatHpText(unit, content)
    local hpValue = hpText:sub(4) -- Remove "HP: " prefix
    local moveRange = tostring(content.move or unitsInfo:getUnitMoveRange(unit, "UI_CLASS_DISPLAY") or "0")
    local attackDamage = tostring(content.atkDamage or unitsInfo:getUnitAttackDamage(unit, "UI_CLASS_DISPLAY") or "0")
    
    -- Check if unit can fly
    local canFly = false
    if content.fly ~= nil then
        canFly = type(content.fly) == "boolean" and content.fly or false
    elseif unit.fly ~= nil then
        canFly = unit.fly
    end
    
    -- Check if unit has ranged attack (attack range > 1 means ranged)
    local attackRange = content.atkRange or unitsInfo:getUnitAttackRange(unit, "UI_CLASS_DISPLAY") or 1
    local isRanged = tonumber(attackRange) > 1
    
    -- Bubble dimensions - make HP bubble wider for "current/max" format
    local hpBubbleWidth = 68  -- Wider for HP text like "12/12" with icon
    local statBubbleWidth = 40  -- Normal width for single digit stats
    local bubbleHeight = 24
    local bubbleSpacing = 6
    local totalWidth = hpBubbleWidth + 2 * statBubbleWidth + 2 * bubbleSpacing
    local startX = x + (width - totalWidth) / 2
    
    -- Faction colors for bubbles
    local bubbleColor, bubbleOutline
    if player == 2 then
        -- Red theme for player 2
        bubbleColor = {255/255, 240/255, 240/255, 0.95}
        bubbleOutline = {140/255, 60/255, 60/255, 1.0}
    else
        -- Blue theme for player 0 and 1
        bubbleColor = {240/255, 248/255, 255/255, 0.95}
        bubbleOutline = {60/255, 80/255, 120/255, 1.0}
    end
    
    local font = love.graphics.getFont()
    local stats = {
        {label = "HP", value = hpValue},
        {label = "MOV", value = moveRange},
        {label = "ATK", value = attackDamage}
    }
    
    -- Draw each bubble with different widths
    local currentX = startX
    for i, stat in ipairs(stats) do
        -- Use wider bubble for HP, normal width for others
        local currentBubbleWidth = (i == 1) and hpBubbleWidth or statBubbleWidth
        
        -- Draw bubble background
        love.graphics.setColor(bubbleColor)
        love.graphics.rectangle("fill", currentX, y, currentBubbleWidth, bubbleHeight, 8)
        
        -- Draw bubble outline
        love.graphics.setColor(bubbleOutline)
        love.graphics.setLineWidth(1.5)
        love.graphics.rectangle("line", currentX, y, currentBubbleWidth, bubbleHeight, 8)
        
        -- Draw stat content (icon + text for HP, text only for others)
        if i == 1 and self.hpIconSprite then
            -- Draw HP icon + text
            local text = stat.value
            local textWidth = font:getWidth(text)
            local textHeight = font:getHeight()
            local iconSize = 24
            local spacing = -8
            local totalWidth = iconSize + spacing + textWidth
            local startContentX = currentX + (currentBubbleWidth - totalWidth) / 2
            
            -- Draw HP icon
            love.graphics.setColor(1, 1, 1, 1)
            local iconX = currentX
            local iconY = y + (bubbleHeight - iconSize) / 2
            local scaleX = iconSize / self.hpIconSprite:getWidth()
            local scaleY = iconSize / self.hpIconSprite:getHeight()
            love.graphics.draw(self.hpIconSprite, iconX, iconY, 0, scaleX, scaleY)
            
            -- Draw HP text
            love.graphics.setColor(0.2, 0.2, 0.2, 0.9)
            local textX = startContentX + iconSize + spacing
            local textY = y - 2 + (bubbleHeight - textHeight) / 2
            love.graphics.print(text, textX, textY)
        elseif i == 2 and (self.flyIconSprite or self.noFlyIconSprite) then
            -- Draw Movement icon + text (fly or no-fly)
            local text = stat.value
            local textWidth = font:getWidth(text)
            local textHeight = font:getHeight()
            local iconSize = 24
            local spacing = 4
            local totalWidth = iconSize + spacing + textWidth
            local startContentX = currentX + (currentBubbleWidth - totalWidth) / 2
            
            -- Draw appropriate fly icon
            love.graphics.setColor(1, 1, 1, 1)
            local flyIcon = canFly and self.flyIconSprite or self.noFlyIconSprite
            if flyIcon then
                local iconX = startContentX
                local iconY = y + (bubbleHeight - iconSize) / 2
                local scaleX = iconSize / flyIcon:getWidth()
                local scaleY = iconSize / flyIcon:getHeight()
                love.graphics.draw(flyIcon, iconX, iconY, 0, scaleX, scaleY)
            end
            
            -- Draw movement text
            love.graphics.setColor(0.2, 0.2, 0.2, 0.9)
            local textX = startContentX + iconSize + spacing
            local textY = y - 2 + (bubbleHeight - textHeight) / 2
            love.graphics.print(text, textX, textY)
        elseif i == 3 and (self.rangedIconSprite or self.meleeIconSprite) then
            -- Draw Attack icon + text (ranged or melee)
            local text = stat.value
            local textWidth = font:getWidth(text)
            local textHeight = font:getHeight()
            local iconSize = 24
            local spacing = 4
            local totalWidth = iconSize + spacing + textWidth
            local startContentX = currentX + (currentBubbleWidth - totalWidth) / 2
            
            -- Draw appropriate attack icon
            love.graphics.setColor(1, 1, 1, 1)
            local attackIcon = isRanged and self.rangedIconSprite or self.meleeIconSprite
            if attackIcon then
                local iconX = startContentX
                local iconY = y + (bubbleHeight - iconSize) / 2
                local scaleX = iconSize / attackIcon:getWidth()
                local scaleY = iconSize / attackIcon:getHeight()
                love.graphics.draw(attackIcon, iconX, iconY, 0, scaleX, scaleY)
            end
            
            -- Draw attack text
            love.graphics.setColor(0.2, 0.2, 0.2, 0.9)
            local textX = startContentX + iconSize + spacing
            local textY = y - 2 + (bubbleHeight - textHeight) / 2
            love.graphics.print(text, textX, textY)
        else
            -- Draw stat text (centered)
            love.graphics.setColor(0.2, 0.2, 0.2, 0.9)
            local text = stat.value
            local textWidth = font:getWidth(text)
            local textHeight = font:getHeight()
            love.graphics.print(text, currentX + (currentBubbleWidth - textWidth) / 2, y - 2 + (bubbleHeight - textHeight) / 2)
        end
        
        -- Move to next bubble position
        currentX = currentX + currentBubbleWidth + bubbleSpacing
    end
end

function uiClass:drawInfoCardGlossOverlay(x, y, width, height, content)
    if not self.cardTemplateImage then
        return
    end

    if not self.infoGlossShader then
        local ok, sh = pcall(love.graphics.newShader, [[
            extern vec2 cardPos;
            extern vec2 cardSize;
            extern float angle;
            extern float bandPos;
            extern float bandWidth;
            extern float intensity;

            vec4 effect(vec4 color, Image texture, vec2 tc, vec2 sc) {
                vec2 local = (sc - cardPos) / cardSize;
                local -= vec2(0.5, 0.5);
                float c = cos(angle);
                float s = sin(angle);
                vec2 r = vec2(c*local.x - s*local.y, s*local.x + c*local.y);
                float rx = r.x / 0.5;
                float d = abs(rx - bandPos);
                float w = max(0.0001, bandWidth);
                float a = smoothstep(w, 0.0, d) * intensity;
                return vec4(1.0, 1.0, 1.0, a);
            }
        ]])
        if ok then
            self.infoGlossShader = sh
            self.infoGlossStates = self.infoGlossStates or {}
        else
            self.infoGlossShader = false
            return
        end
    end

    if not self.infoGlossShader then
        return
    end

    self.infoGlossStates = self.infoGlossStates or {}
    self.infoGlossGroups = self.infoGlossGroups or {}

    local cardWidth = self.cardTemplateImage:getWidth()
    local cardHeight = self.cardTemplateImage:getHeight()
    local cardScale = math.min(width / cardWidth, height / cardHeight)
    local cW = cardWidth * cardScale
    local cH = cardHeight * cardScale
    local cX = x + (width - cW) / 2
    local cY = y + (height - cH) / 2

    local glossKey = (type(content) == "table" and content.glossKey) or "default"
    local glossGroup = (type(content) == "table" and content.glossGroup) or nil
    local glossGroupState = nil
    if glossGroup then
        glossGroupState = self.infoGlossGroups[glossGroup]
        if not glossGroupState then
            glossGroupState = {activeKey = nil, lastKey = nil, nextAt = 0}
            self.infoGlossGroups[glossGroup] = glossGroupState
        end
    end

    local st = self.infoGlossStates[glossKey]
    local now = love.timer.getTime()
    if not st then
        local initialGap = (glossKey == "default") and (math.random() * 1.5) or (1.4 + math.random() * 2.2)
        st = { start = 0, duration = 0, nextAt = now + initialGap, dir = 1 }
        self.infoGlossStates[glossKey] = st
    end

    local canStartGloss = now >= (st.nextAt or 0) and (st.start or 0) == 0
    if glossGroupState then
        canStartGloss = canStartGloss and now >= (glossGroupState.nextAt or 0) and
            (glossGroupState.activeKey == nil or glossGroupState.activeKey == glossKey)
    end

    if canStartGloss then
        st.start = now
        st.dir = (math.random() < 0.5) and -1 or 1
        local angle = math.rad(35)
        local bandW_dyn = math.max(10, cW * 0.12)
        local halfExtent = 0.5 * (cW * math.cos(angle) + cH * math.sin(angle))
        local span = halfExtent + bandW_dyn * 1.25
        local speed = math.max(110, cW * 0.6)
        st.duration = (2 * span) / speed
        local idleGap = (glossKey == "default") and (0.5 + math.random() * 0.7) or (2.4 + math.random() * 2.8)
        st.nextAt = now + st.duration + idleGap
        if glossGroupState then
            glossGroupState.activeKey = glossKey
        end
    end

    local active = st and st.start and st.start > 0 and now < (st.start + st.duration)
    if active then
        local t = (now - st.start) / st.duration
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local easedT = t * t * (3 - 2 * t)

        love.graphics.stencil(function()
            local inset = math.max(2, math.min(cW, cH) * 0.03)
            local maskX = cX + inset
            local maskY = cY + inset
            local maskW = cW - inset * 2
            local maskH = cH - inset * 2
            local r = math.min(maskW, maskH) * 0.12
            love.graphics.rectangle("fill", maskX, maskY, maskW, maskH, r, r)
        end, "replace", 1)
        love.graphics.setStencilTest("greater", 0)

        local prevBlend, prevAlpha = love.graphics.getBlendMode()
        love.graphics.setBlendMode("add", "alphamultiply")

        love.graphics.push()
        local cx = cX + cW / 2
        local cy = cY + cH / 2
        love.graphics.translate(cx, cy)
        local angle = math.rad(35)
        love.graphics.rotate(angle)

        local bandW = math.max(10, cW * 0.12)
        local halfExtent = 0.5 * (cW * math.cos(angle) + cH * math.sin(angle))
        local span = math.max(0, halfExtent - bandW * 0.5)
        local rx = st.dir * (-span + 2 * span * easedT)
        local diag = math.sqrt(cW * cW + cH * cH)
        local h = diag * 2
        local fade = math.sin(easedT * math.pi)
        local alpha = 0.18 * fade
        love.graphics.setColor(1, 1, 1, alpha)
        love.graphics.rectangle("fill", rx - bandW / 2, -h / 2, bandW, h)
        love.graphics.pop()

        love.graphics.setBlendMode(prevBlend, prevAlpha)
        love.graphics.setStencilTest()
    elseif st and st.start and now >= (st.start + st.duration) then
        st.start = 0
        st.duration = 0
        if glossGroupState and glossGroupState.activeKey == glossKey then
            glossGroupState.activeKey = nil
            glossGroupState.lastKey = glossKey
            glossGroupState.nextAt = now + (0.25 + math.random() * 0.45)
            st.nextAt = now + (3.1 + math.random() * 2.6)
        end
    end
end

function uiClass:drawUnitInfoPanel(x, y, width, height, gameRuler)
    if not gameRuler then gameRuler = self.gameRuler end

    -- In AI vs AI mode, don't force default panel - keep showing AI unit info
    if self.forceInfoPanelDefault and GAME.CURRENT.MODE ~= GAME.MODE.AI_VS_AI then
        self:setContent(nil)
        self:drawInfoPanel()
        return
    end

    if gameRuler.currentGrid and gameRuler.currentGrid.movingUnits and 
       #gameRuler.currentGrid.movingUnits > 0 then
        -- Only draw the existing panel without processing hover cells
        self:drawInfoPanel()
        return
    end

    if self.selectedUnit and (
       (self.gameRuler.currentPhase == "deploy1_units" or 
        self.gameRuler.currentPhase == "deploy2_units") or
       (self.gameRuler.currentPhase == "turn" and 
        self.gameRuler.currentTurnPhase == "supply")) then

        -- During deployment or supply phase, prioritize showing the selected supply unit
        local unitInfo = self:createUnitInfoFromUnit(self.selectedUnit, self.selectedUnitPlayer)
        self:setContent(unitInfo, self.playerThemes[self.selectedUnitPlayer or 0])
        self:drawInfoPanel()
        return
    end

    -- Standard info panel display logic for non-deployment phases
    local displayUnit = nil
    local displayCell = nil

    if self.gameRuler.currentGrid and self.gameRuler.currentGrid.selectedUnit then
        -- Option 1: Show selected unit info, regardless of mouse position
        displayUnit = self.gameRuler.currentGrid.selectedUnit
    elseif self.gameRuler.currentGrid and self.gameRuler.currentGrid.mouseHoverCell and self.gameRuler.currentGrid.mouseHoverCell.unit then
        -- Option 2: Show info for unit under mouse cursor
        displayCell = self.gameRuler.currentGrid.mouseHoverCell
        displayUnit = displayCell.unit
    elseif self.gameRuler.currentGrid and self.gameRuler.currentGrid.mouseHoverCell then
        -- Option 3: Show tile info when hovering empty cell
        displayCell = self.gameRuler.currentGrid.mouseHoverCell
    end

    -- Update the info panel content based on what should be displayed
    if displayUnit then
        local unitInfo = self:createUnitInfoFromUnit(displayUnit, displayUnit.player)
        self:setContent(unitInfo, self.playerThemes[displayUnit.player or 0])
    elseif displayCell then
        -- Create cell info
        local cellInfo = {
            status = "Empty Cell",
            position = self.gameRuler.currentGrid:gridToChessNotation(displayCell.row, displayCell.col),
            terrain = displayCell.terrain or "Normal"
        }

        if displayCell.actionHighlight then
            cellInfo.action = displayCell.actionHighlight
        end

        self:setContent(cellInfo, self.playerThemes[0])
    else
        -- In AI vs AI mode, keep the last set content instead of clearing
        if GAME.CURRENT.MODE ~= GAME.MODE.AI_VS_AI then
            self:setContent(nil)
        end
    end

    -- Draw the info panel with the updated content
    self:drawInfoPanel()
end

function uiClass:drawUnitInfoContent(x, y, width, height, unit, player, content, colors)
    -- Define layout parameters
    local lineHeight = 24
    local startY = y - 24
    local padding = 15
    local textWidth = width - padding * 2

    -- Get stat values
    local hpText = self:formatHpText(unit, content)
    local hpValue = hpText:sub(4) -- Remove "HP: " prefix
    local moveRange = tostring(content.move or unitsInfo:getUnitMoveRange(unit, "UI_CLASS_DISPLAY") or "0")
    local attackRange = tostring(content.atkRange or unitsInfo:getUnitAttackRange(unit, "UI_CLASS_DISPLAY") or "0")
    local attackDamage = tostring(content.atkDamage or unitsInfo:getUnitAttackDamage(unit, "UI_CLASS_DISPLAY") or "0")

    local font = love.graphics.getFont()

    -- Draw unit icon at the center of the card (for all units including Rocks)
    local iconPath = nil
    if unit then

        if player == 2 then
            -- For player 2, prefer red icon, fallback to default if red doesn't exist
            iconPath = unit.pathUiIconRed or unit.pathUiIcon
        elseif player == 0 then
            -- Explicitly handle player 0 (Rocks)
            iconPath = unit.pathUiIcon
        elseif player == 1 then
            -- For player 1, use default icon (blue)
            iconPath = unit.pathUiIcon
        else
            -- Fallback for any other player
            iconPath = unit.pathUiIcon
        end

        if iconPath then
            local unitIcon = self:getUnitImage(unit, player)
            if unitIcon then
                local iconSize = 128
                local iconX = x + (width - iconSize) / 2 - 4
                local iconY = y + (height - iconSize) / 2 - 32
                local scaleX = iconSize / unitIcon:getWidth()
                local scaleY = iconSize / unitIcon:getHeight()

                self:drawUnitShadow(unitIcon, iconX, iconY, scaleX, scaleY, unit)

                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.draw(unitIcon, iconX, iconY, 0, scaleX, scaleY)
            end
        end
    end


    -- Draw faction-colored background for description area only
    local bubbleColor, bubbleOutline
    if player == 2 then
        -- Red theme for player 2
        bubbleColor = {255/255, 240/255, 240/255, 0.95}    -- Light red-white
        bubbleOutline = {140/255, 60/255, 60/255, 1.0}     -- Dark red outline
    else
        -- Blue theme for player 0 and 1
        bubbleColor = {240/255, 248/255, 255/255, 0.95}    -- Light blue-white
        bubbleOutline = {60/255, 80/255, 120/255, 1.0}     -- Dark blue outline
    end
    
    -- Calculate description area dimensions
    local descX = x + 18
    local descY = y + 166
    local descWidth = width - 36
    local descHeight = 72
    
    -- Draw background rectangle with faction colors for description only
    love.graphics.setColor(bubbleColor)
    love.graphics.rectangle("fill", descX, descY, descWidth, descHeight, 6)
    
    -- Draw outline
    love.graphics.setColor(bubbleOutline)
    love.graphics.setLineWidth(1.5)
    love.graphics.rectangle("line", descX, descY, descWidth, descHeight, 6)
    
    -- Special abilities text with bright color for better readability
    love.graphics.setColor(0.3, 0.3, 0.3, 0.95)
    local specialAbilities = content.specialAbilitiesDescriptions or unit.specialAbilitiesDescriptions or "None"
    
    -- Use smaller font for specific units with longer descriptions
    local defaultFont = love.graphics.getFont()
    local needsSmallerFont = false
    if unit and unit.name then
        local unitName = unit.name
        if unitName == "Commandant" or unitName == "Cloudstriker" or unitName == "Artillery" then
            needsSmallerFont = true
        end
    end
    
    if needsSmallerFont then
        local smallFont = getMonogramFont(SETTINGS.FONT.INFO_SIZE)
        love.graphics.setFont(smallFont)
    end
    
    love.graphics.printf(specialAbilities, x + 24, y + 166, textWidth - 30, "left")
    
    -- Restore original font
    love.graphics.setFont(defaultFont)
end

function uiClass:formatHpText(unit, content)
    local hp = "0"

    if content and content.hp then
            hp = content.hp
    elseif unit then
        if unit.currentHp and unit.startingHp then
            hp = unit.currentHp .. "/" .. unit.startingHp
        elseif unit.startingHp then
            hp = unit.startingHp
        else
            hp = "N/A"
        end
    end

    return "HP: " .. tostring(hp)
end

function uiClass:drawEmptyCellContent(x, y, width, height, content, color)
    -- Use dark color for empty cell text
    love.graphics.setColor(0.3, 0.3, 0.3, 0.9)
    
    local text = "CELL " .. content.position
    local font = love.graphics.getFont()
    local textWidth = font:getWidth(text)
    local textHeight = font:getHeight()
    
    -- Center the text horizontally and vertically within the card
    local centerX = x + (width - textWidth) / 2
    local centerY = y - 16
    
    love.graphics.print(text, centerX, centerY)
end

function uiClass:drawDefaultInfoContent(x, y, width, colors)
    --love.graphics.setColor(0.3, 0.3, 0.3, 0.9)
    --love.graphics.printf("Select a unit or hoover a cell to view information.", x + 24, y + 172, width - 30, "left")
end

function uiClass:drawPhaseInfo(x, y, width, height, gameRuler)
    if not gameRuler then gameRuler = self.gameRuler end
    if gameRuler and gameRuler.currentPhase == "gameOver" and self.gameOverPanel and self.gameOverPanel.visible == false then
        return
    end
    local phaseInfo = gameRuler and gameRuler:getCurrentPhaseInfo() or {}

    -- Draw the new comic-style speech bubble UI
    self:drawComicStyleActionPanel(x, y, width, height, phaseInfo)
end

function uiClass:drawComicStyleActionPanel(x, y, width, height, phaseInfo)
    -- In online matches, keep action-panel avatar/theme tied to the local faction.
    local currentPlayer = (phaseInfo and phaseInfo.currentPlayer) or 1
    if GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET and GAME.getLocalFactionId then
        local localFaction = GAME.getLocalFactionId()
        if localFaction == 1 or localFaction == 2 then
            currentPlayer = localFaction
        end
    end
    local useRedTheme = (currentPlayer == 2)

    -- Load appropriate sprite based on player
    if useRedTheme then
        if not self.redRadioSprite then
            self.redRadioSprite = love.graphics.newImage("assets/sprites/Red_Radio.png")
        end
        self.currentRadioSprite = self.redRadioSprite
    else
        if not self.bluRadioSprite then
            self.bluRadioSprite = love.graphics.newImage("assets/sprites/Blu_Radio.png")
        end
        self.currentRadioSprite = self.bluRadioSprite
    end
    
    -- Theme-based colors
    local bubbleColor, bubbleOutline, textColor
    if useRedTheme then
        -- Red theme for player 2
        bubbleColor = {255/255, 240/255, 240/255, 0.95}    -- Light red-white
        bubbleOutline = {140/255, 60/255, 60/255, 1.0}     -- Dark red outline
        textColor = {80/255, 40/255, 40/255, 1.0}          -- Dark red-brown text
    else
        -- Blue theme for player 0 and 1
        bubbleColor = {240/255, 248/255, 255/255, 0.95}    -- Light blue-white
        bubbleOutline = {60/255, 80/255, 120/255, 1.0}     -- Dark blue outline
        textColor = {40/255, 40/255, 60/255, 1.0}          -- Dark blue-gray text
    end

    -- Button dimensions (matching drawPhaseButtonStandard)
    local padding = 15
    local buttonWidth = width - padding * 2
    local buttonHeight = 40
    local buttonY = y + height - buttonHeight - padding
    local buttonX = x + padding

    -- Sprite dimensions and positioning - over button, under bubble
    local spriteWidth = self.currentRadioSprite:getWidth()
    local spriteHeight = self.currentRadioSprite:getHeight()
    local spriteScale = 0.20  -- Smaller sprite to fit between bubble and button
    local scaledSpriteWidth = spriteWidth * spriteScale
    local scaledSpriteHeight = spriteHeight * spriteScale

    -- Position sprite centered horizontally, between bubble and button
    local spriteX = x + (width - scaledSpriteWidth) / 2
    local spriteY = buttonY - scaledSpriteHeight + 16  -- 10px gap above button

    -- Speech bubble dimensions - positioned above the sprite
    local bubbleX = x + 15
    local bubbleY = y + 15
    local bubbleWidth = width - 30
    local bubbleHeight = spriteY - bubbleY - 15 + 4  -- End just above the sprite with 15px gap, increased by 4px

    -- Draw speech bubble background
    love.graphics.setColor(bubbleColor)
    love.graphics.rectangle("fill", bubbleX, bubbleY, bubbleWidth, bubbleHeight, 15)

    -- Draw speech bubble outline
    love.graphics.setColor(bubbleOutline)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", bubbleX, bubbleY, bubbleWidth, bubbleHeight, 15)

    -- Draw animated speech bubble tail pointing down to sprite
    local tailCenterX = bubbleX + bubbleWidth/2 + self.bubbleTriangle.offsetX
    local tailCenterY = bubbleY + bubbleHeight + self.bubbleTriangle.offsetY
    
    -- Apply scale transformation
    love.graphics.push()
    love.graphics.translate(tailCenterX, tailCenterY)
    love.graphics.scale(self.bubbleTriangle.scale, self.bubbleTriangle.scale)
    love.graphics.translate(-tailCenterX, -tailCenterY)
    
    local tailPoints = {
        tailCenterX - 12, bubbleY + bubbleHeight,
        tailCenterX, tailCenterY + 15,
        tailCenterX + 12, bubbleY + bubbleHeight
    }
    love.graphics.polygon("fill", tailPoints)
    love.graphics.polygon("line", tailPoints)
    
    love.graphics.pop()

    -- Draw the current radio sprite (blue or red based on player)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(self.currentRadioSprite, spriteX, spriteY, 0, spriteScale, spriteScale)

    -- Draw action description text in the speech bubble
    -- Save current font and set bubble text font
    local defaultFont = love.graphics.getFont()
    local bubbleTextFont = getMonogramFont(SETTINGS.FONT.DEFAULT_SIZE)
    love.graphics.setFont(bubbleTextFont)
    
    love.graphics.setColor(textColor)
    local textPadding = 20
    local textX = bubbleX + textPadding
    local textY = bubbleY + 10  -- Start text higher up in the bubble
    local textWidth = bubbleWidth - textPadding * 2

    -- Get action description
    local actionText = self:getActionDescription(phaseInfo)

    -- Draw the text with comic-style formatting
    love.graphics.printf(actionText, textX - 8, textY - 8, textWidth, "left")
    
    -- Restore original font
    love.graphics.setFont(defaultFont)

    -- Draw the phase button (preserve existing functionality)
    self:drawPhaseButtonStandard(x, y, width, height, phaseInfo, {})

    love.graphics.setLineWidth(1) -- Reset line width
end

function uiClass:updateTypewriter(dt)
    if not self.typewriter.isActive then
        return
    end
    
    self.typewriter.timer = self.typewriter.timer + dt
    
    if self.typewriter.timer >= self.typewriter.speed then
        self.typewriter.timer = 0
        self.typewriter.currentIndex = self.typewriter.currentIndex + 1
        
        if self.typewriter.currentIndex <= #self.typewriter.text then
            self.typewriter.displayedText = string.sub(self.typewriter.text, 1, self.typewriter.currentIndex)
            
            -- Play typewriter sound for each character
            if SETTINGS.AUDIO.SFX then
                soundCache.play("assets/audio/ClickyButton4.wav", { clone = true, volume = SETTINGS.AUDIO.SFX_VOLUME * 0.3, category = "sfx" })
            end
        else
            self.typewriter.isActive = false
        end
    end
end

function uiClass:updateTurnZoom(dt)
    if not self.turnZoom.isActive then
        return
    end
    
    self.turnZoom.timer = self.turnZoom.timer + dt
    local progress = self.turnZoom.timer / self.turnZoom.duration
    
    if progress >= 1.0 then
        -- Animation complete
        self.turnZoom.isActive = false
        self.turnZoom.scale = 1.0
        self.turnZoom.colorIntensity = 1.0
        self.turnZoom.timer = 0
    else
        -- Use smooth easing curve for more natural feel
        local easedProgress = progress < 0.5 
            and 2 * progress * progress 
            or 1 - ((-2 * progress + 2) ^ 3) / 2
        
        -- Single smooth curve instead of two phases
        local curve = math.sin(easedProgress * math.pi)
        
        -- Apply smooth scaling
        self.turnZoom.scale = 1.0 + (self.turnZoom.maxScale - 1.0) * curve
        
        -- Apply smooth color transition
        self.turnZoom.colorIntensity = 1.0 + 0.4 * curve -- Less intense white
    end
end

function uiClass:startTurnZoom()
    self.turnZoom.isActive = true
    self.turnZoom.scale = 1.0
    self.turnZoom.colorIntensity = 1.0
    self.turnZoom.timer = 0
end

function uiClass:updateBubbleTriangle(dt)
    self.bubbleTriangle.timer = self.bubbleTriangle.timer + dt
    
    -- Wiggle left and right
    self.bubbleTriangle.offsetX = math.sin(self.bubbleTriangle.timer * self.bubbleTriangle.wiggleSpeed * 2 * math.pi) * self.bubbleTriangle.wiggleAmount
    
    -- Subtle up and down movement
    self.bubbleTriangle.offsetY = math.sin(self.bubbleTriangle.timer * self.bubbleTriangle.wiggleSpeed * 1.3 * math.pi) * (self.bubbleTriangle.wiggleAmount * 0.5)
    
    -- Pulse scale in and out
    self.bubbleTriangle.scale = 1.0 + math.sin(self.bubbleTriangle.timer * self.bubbleTriangle.pulseSpeed * 2 * math.pi) * self.bubbleTriangle.pulseAmount
end

function uiClass:startTypewriter(text)
    if text == self.typewriter.lastText then
        -- Same text - if finished, show all; if active, continue
        if not self.typewriter.isActive then
            self.typewriter.displayedText = text
        end
        return
    end
    
    -- In AI vs AI mode, show text instantly without typewriter effect
    if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI then
        self.typewriter.text = text
        self.typewriter.lastText = text
        self.typewriter.displayedText = text -- Show all text immediately
        self.typewriter.currentIndex = #text
        self.typewriter.timer = 0
        self.typewriter.isActive = false -- No animation
        
        -- Play sound once when message changes
        if SETTINGS.AUDIO.SFX then
            soundCache.play("assets/audio/ClickyButton4.wav", { clone = true, volume = SETTINGS.AUDIO.SFX_VOLUME * 0.5, category = "sfx" })
        end
        return
    end
    
    -- New text - start typewriter effect for human players
    self.typewriter.text = text
    self.typewriter.lastText = text
    self.typewriter.displayedText = "" -- Start empty for typewriter effect
    self.typewriter.currentIndex = 0 -- Start at beginning
    self.typewriter.timer = 0
    self.typewriter.isActive = true -- Enable animation
end


function uiClass:getActionDescription(phaseInfo)
    local text
    local currentPlayer = (phaseInfo and phaseInfo.currentPlayer) or (self.gameRuler and self.gameRuler.currentPlayer)

    if self:isOnlineNonLocalTurn({currentPlayer = currentPlayer}) then
        local ownerName = self:getFactionDisplayName(currentPlayer, "Player")
        text = string.format("%s turn", ownerName)
    elseif GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and currentPlayer == GAME.CURRENT.AI_PLAYER_NUMBER then
        text = "AI TURN..."
    else
        text = (phaseInfo and phaseInfo.instructions) or "Select a unit and choose an action to continue."
    end

    self:startTypewriter(text)
    return self.typewriter.displayedText
end
function uiClass:getAvailableDeploymentCells(phaseInfo)
    if not self.gameRuler or not phaseInfo.currentPlayer then
        return 0
    end

    local hubPos = self.gameRuler.commandHubPositions[phaseInfo.currentPlayer]
    if not hubPos then
        return 0
    end

    local grid = self.gameRuler.currentGrid
    if not grid then 
        return 0
    end

    -- Count free cells ORTHOGONALLY around Commandant
    local freeCells = 0
    local directions = {
        {-1, 0}, {1, 0}, {0, -1}, {0, 1}
    }

    for _, dir in ipairs(directions) do
        local checkRow = hubPos.row + dir[1]
        local checkCol = hubPos.col + dir[2]

        local withinBounds = checkRow >= 1 and checkRow <= grid.rows and checkCol >= 1 and checkCol <= grid.cols
        if withinBounds then
            local cell = grid:getCell(checkRow, checkCol)
            if cell and not cell.unit then
                freeCells = freeCells + 1
            end
        end
    end

    return freeCells
end

-- Helper function to get units in supply
function uiClass:getUnitsInSupply(playerNum)
    if playerNum == 1 then
        return self.playerSupply1
    elseif playerNum == 2 then
        return self.playerSupply2
    end
    return {}
end

function uiClass:initializeGameOverPanel()
    local baseHeight = 650

    self.gameOverPanel = {
        targetY = 30,
        currentY = -450,
        width = SETTINGS.DISPLAY.WIDTH * 0.8,
        height = baseHeight,
        animating = false,
        animationComplete = false,
        bouncing = false,
        bounceVelocity = 0,
        visible = true,
        button = {
            x = 0,
            y = 0,
            width = 220,
            height = 50,
            text = "Return to Main Menu",
            currentColor = self.colors.button,
            hoverColor = self.colors.buttonHover,
        },
        toggleButton = {
            x = 0,
            y = 0,
            width = 220,
            height = 50,
            text = "Show the Battlefield",
            currentColor = self.colors.button,
            hoverColor = self.colors.buttonHover
        },
        returnButton = {
            x = SETTINGS.DISPLAY.WIDTH - 250,
            y = 410,
            width = 220,
            height = 50,
            text = "Return to Results",
            currentColor = self.colors.button,
            hoverColor = self.colors.buttonHover,
            visible = true
        },
        confettiParticles = {},
        confettiPool = {},
        confettiActive = false,
        confettiSpawned = false
    }
end

function uiClass:drawBackToMenuButton(x, y, width, height)
    local padding = 15
    local buttonWidth = width - padding * 2
    local buttonHeight = 40
    local buttonX = x + padding
    local buttonY = y + height - buttonHeight - padding + 16  -- Moved down by 24 pixels (30 - 6)
    
    -- Button colors matching brown panel theme (like supply panels)
    local normalColor = {60/255, 50/255, 40/255, 0.95}      -- Brown like supply panels
    local hoverColor = {80/255, 65/255, 50/255, 0.98}       -- Lighter brown on hover
    local pressedColor = {45/255, 38/255, 30/255, 0.95}     -- Darker brown on press
    
    -- Check if mouse is over button
    local mouseX, mouseY = love.mouse.getPosition()
    local tx = (mouseX - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (mouseY - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
    
    local isHovered = tx >= buttonX and tx <= buttonX + buttonWidth and
                      ty >= buttonY and ty <= buttonY + buttonHeight
    
    -- Store button info for click handling
    self.phaseButton = {
        x = buttonX,
        y = buttonY,
        width = buttonWidth,
        height = buttonHeight,
        action = "backToMenu",
        text = "STOP GAME"
    }
    
    -- Always use hover color to show it's always focused
    local currentColor = hoverColor
    if self.phaseButtonLock.active then
        currentColor = pressedColor
    end
    
    -- Draw button background
    love.graphics.setColor(currentColor)
    love.graphics.rectangle("fill", buttonX, buttonY, buttonWidth, buttonHeight, 5, 5)
    
    -- Draw button border with focus glow (whitish border like focused elements)
    love.graphics.setColor(255/255, 240/255, 220/255, 0.8)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", buttonX, buttonY, buttonWidth, buttonHeight, 5, 5)
    
    -- Draw button text
    love.graphics.setColor(240/255, 230/255, 210/255, 1)  -- Light warm text
    local font = love.graphics.getFont()
    local text = "STOP GAME"
    local textWidth = font:getWidth(text)
    local textHeight = font:getHeight()
    local textX = buttonX + (buttonWidth - textWidth) / 2
    local textY = buttonY + (buttonHeight - textHeight) / 2
    love.graphics.print(text, textX, textY)
    
    love.graphics.setLineWidth(1)
end

function uiClass:drawPhaseButtonStandard(x, y, width, height, phaseInfo, colors)
    local buttonInfo = self:getPhaseButtonInfo(phaseInfo)

    if self.phaseButtonLock.active then
        local phaseChanged = phaseInfo.currentPhase ~= self.phaseButtonLock.phase or
                             phaseInfo.turnPhaseName ~= self.phaseButtonLock.turnPhase

        if buttonInfo.disabled or phaseChanged then
            self.phaseButtonLock.active = false
        else
            self.phaseButton = nil
            return
        end
    end

    if not self:canShowOnlineReactionButtons(phaseInfo) then
        self:clearOnlineReactionButtonsLayout()
    end

    -- Don't show phase button if game is over
    if phaseInfo.currentPhase == "gameOver" then
        self.phaseButton = nil
        return
    end

    if GAME and GAME.CURRENT and GAME.MODE and GAME.CURRENT.MODE == GAME.MODE.SCENARIO then
        self.phaseButton = nil
        self.pulsing.active = false
        return
    end

    -- Check if it's AI's turn in single player mode
    if GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and phaseInfo.currentPlayer == GAME.CURRENT.AI_PLAYER_NUMBER then
        -- Hide the button during AI turn
        self.phaseButton = nil
        return
    end

    -- In local human modes, keep manual confirmation only for Commandant placement.
    -- Every other phase transition is auto-accepted by gameplay flow.
    if self:shouldHideAutomaticSinglePlayerPhaseButton(phaseInfo, buttonInfo) then
        self.pulsing.active = false
        self.phaseButton = nil
        return
    end

    -- In online multiplayer, reuse the phase-button space for reaction buttons on non-local turns.
    if self:isOnlineNonLocalTurn(phaseInfo) then
        self.phaseButton = nil
        if self:canShowOnlineReactionButtons(phaseInfo) then
            self:drawOnlineReactionButtons(x, y, width, height, phaseInfo)
        else
            self:clearOnlineReactionButtonsLayout()
        end
        return
    end

    self:clearOnlineReactionButtonsLayout()

    if self:shouldHideAutomaticOnlinePhaseButton(phaseInfo, buttonInfo) then
        self.pulsing.active = false
        self.phaseButton = nil
        return
    end
    
    -- In AI vs AI mode, show "Back to Menu" button instead of phase button
    if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI then
        self:drawBackToMenuButton(x, y, width, height)
        return
    end

    -- If the button is disabled, don't draw it at all
    if buttonInfo.disabled then
        -- Set phaseButton to nil so click handler knows there's no button
        self.phaseButton = nil
        return
    end

    -- Determine current player and set theme colors
    local currentPlayer = phaseInfo.currentPlayer or 1
    local useRedTheme = (currentPlayer == 2)
    
    -- Theme-based button colors following MOM (main menu) color scheme
    local normalColor, hoverColor, pressedColor
    if useRedTheme then
        -- Red theme for player 2 - based on MOM redTeam color (0.8, 0.2, 0.2, 1)
        normalColor = {0.8, 0.2, 0.2, 0.9}              -- Red team color from MOM
        hoverColor = {0.9, 0.3, 0.3, 0.95}              -- Brighter red hover
        pressedColor = {0.6, 0.15, 0.15, 0.9}           -- Darker red pressed
    else
        -- Blue theme for player 0 and 1 - based on MOM blueTeam color (0.2, 0.4, 0.8, 1)
        normalColor = {0.2, 0.4, 0.8, 0.9}              -- Blue team color from MOM
        hoverColor = {0.3, 0.5, 0.9, 0.95}              -- Brighter blue hover
        pressedColor = {0.15, 0.3, 0.6, 0.9}            -- Darker blue pressed
    end

    -- Initialize phaseButton first to avoid nil errors
    if not self.phaseButton then
        self.phaseButton = {
            x = x + 15,
            y = y + height - 40 - 15,
            width = width - 30,
            height = 40,
            text = phaseInfo.turnPhaseName,
            actionType = buttonInfo.actionType,
            normalColor = normalColor,
            hoverColor = hoverColor,
            pressedColor = pressedColor,
            currentColor = normalColor   -- Default to normal color
        }
    else
        -- Update colors for existing button
        self.phaseButton.normalColor = normalColor
        self.phaseButton.hoverColor = hoverColor
        self.phaseButton.pressedColor = pressedColor
        -- DON'T reset currentColor here - it may have been set by hover detection
        -- self.phaseButton.currentColor = normalColor
    end

    -- Update button properties - must match comic panel positioning
    local padding = 15
    local buttonWidth = width - padding * 2
    local buttonHeight = 40
    local buttonY = y + height - buttonHeight - padding + 12  -- Match comic panel offset
    local buttonX = x + padding
    local buttonScale, buttonOffset, colorMod = self:calculateButtonAnimationValues(buttonX, buttonY)

    -- Update button properties
    self.phaseButton.x = buttonX
    self.phaseButton.y = buttonY
    self.phaseButton.width = buttonWidth
    self.phaseButton.height = buttonHeight
    self.phaseButton.text = buttonInfo.text
    self.phaseButton.actionType = buttonInfo.actionType

    -- Apply button scale if needed
    if buttonScale ~= 1 then
        self:applyButtonScale(buttonX, buttonY, buttonWidth, buttonHeight, buttonScale)
    end

    -- Button background
    love.graphics.setColor(self.phaseButton.currentColor)
    love.graphics.rectangle("fill", buttonX, buttonY + buttonOffset, buttonWidth, buttonHeight, 8)

    -- Pre-calc themed border colors so button matches faction palette
    local baseBorderColor = uiTheme.darken(normalColor, 0.15)
    local accentGlowColor = uiTheme.lighten(normalColor, 0.35)

    -- Button border - themed color for idle, brighter tint for hover/focus
    local isMouseHovered = false
    if self.phaseButton.hoverColor then
        -- Compare color values directly
        local current = self.phaseButton.currentColor
        local hover = self.phaseButton.hoverColor
        isMouseHovered = (current[1] == hover[1] and current[2] == hover[2] and 
                         current[3] == hover[3] and current[4] == hover[4])
    end
    
    local isKeyboardFocused = (self.uIkeyboardNavigationActive and self.activeUIElement and 
                              self.activeUIElement.name == "phaseButton")
    
    if isMouseHovered or isKeyboardFocused then
        love.graphics.setColor(255/255, 240/255, 220/255, 0.8)
        love.graphics.setLineWidth(2.5)
    else
        love.graphics.setColor(baseBorderColor[1], baseBorderColor[2], baseBorderColor[3], baseBorderColor[4] or 0.9)
        love.graphics.setLineWidth(2)
    end
    love.graphics.rectangle("line", buttonX, buttonY + buttonOffset, buttonWidth, buttonHeight, 8)
    love.graphics.setLineWidth(1)

    -- Inner accent line (subtle highlight for depth)
    if isMouseHovered or isKeyboardFocused then
        love.graphics.setColor(accentGlowColor[1], accentGlowColor[2], accentGlowColor[3], accentGlowColor[4] or 0.35)
        love.graphics.rectangle("line", buttonX + 3, buttonY + buttonOffset + 3, buttonWidth - 6, buttonHeight - 6, 6)
    end

    -- Button text
    -- Save current font and set phase button font
    local defaultFont = love.graphics.getFont()
    local phaseButtonFont = getMonogramFont(SETTINGS.FONT.DEFAULT_SIZE)
    love.graphics.setFont(phaseButtonFont)
    
    love.graphics.setColor(1, 1, 1, 0.95)  -- White text for better contrast on blue/red backgrounds
    love.graphics.printf(buttonInfo.text, buttonX, buttonY + buttonOffset - 2 + (buttonHeight - phaseButtonFont:getHeight())/2, buttonWidth, "center")
    
    -- Restore original font
    love.graphics.setFont(defaultFont)

    -- Restore scale if changed
    if buttonScale ~= 1 then
        love.graphics.pop()
    end
end

function uiClass:getPhaseButtonInfo(phaseInfo)
    local buttonText = "Next Phase"
    local actionType = ""
    local buttonDisabled = false

    if phaseInfo.currentPhase == "setup" then
         if self.gameRuler and self.gameRuler.neutralBuildingPlacementInProgress then
            buttonText = "Placing Rocks..."
            actionType = ""
            buttonDisabled = true
        else
            buttonText = "PLACE RANDOM ROCKS"
            actionType = "placeAllNeutralBuildings"
            buttonDisabled = false
        end
    elseif phaseInfo.currentPhase == "deploy1" or phaseInfo.currentPhase == "deploy2" then
        buttonText = "CONFIRM PLACEMENT"
        actionType = "confirmCommandHub"
        buttonDisabled = not (self.gameRuler and self.gameRuler.commandHubPlacementReady)
    elseif phaseInfo.currentPhase == "deploy1_units" or phaseInfo.currentPhase == "deploy2_units" then
        buttonText = "END DEPLOYMENT PHASE"
        actionType = "confirmDeployment"
        buttonDisabled = not (self.gameRuler and self.gameRuler:isInitialDeploymentComplete())
    elseif phaseInfo.currentPhase == "turn" then
        if phaseInfo.turnPhaseName == "commandHub" then
            -- **UPDATED: Never show a button for Commandant phase**
            if self.gameRuler.commandHubDefenseActive then
                if self.gameRuler.commandHubDefenseComplete then
                    -- **AUTO-ADVANCE: Automatically go to actions phase**
                    self.gameRuler:scheduleAction(0.1, function()
                        self.gameRuler:nextTurnPhase()
                    end)
                    buttonText = "Advancing to Actions..."
                    buttonDisabled = true
                else
                    buttonText = "Commandant Defense..."
                    buttonDisabled = true
                end
            else
                buttonText = "Commandant Defense..."
                buttonDisabled = true
            end

        elseif phaseInfo.turnPhaseName == "actions" then
            buttonText = "END YOUR TURN"
            actionType = "endActions"

            local actionsComplete = self.gameRuler:areActionsComplete()
            buttonDisabled = not actionsComplete
        end
    elseif phaseInfo.currentPhase == "gameOver" then
        buttonText = "Main Menu"
        actionType = "ReturnToMainMenu"
    end

    local shouldPulse = false

    if phaseInfo.currentPhase == "deploy1_units" or phaseInfo.currentPhase == "deploy2_units" then
        shouldPulse = self.gameRuler and self.gameRuler:isInitialDeploymentComplete()
    elseif phaseInfo.currentPhase == "turn" then
        if phaseInfo.turnPhaseName == "actions" then
            -- **FIXED: Pulse when actions are complete**
            shouldPulse = self.gameRuler and self.gameRuler:areActionsComplete()
        elseif phaseInfo.turnPhaseName == "commandHub" then
            -- **FIXED: Pulse when Commandant defense is complete**
            shouldPulse = self.gameRuler and self.gameRuler.commandHubDefenseComplete
        end
    else
        shouldPulse = true
    end

    self.pulsing.active = shouldPulse and not buttonDisabled

    return {
        text = buttonText,
        actionType = actionType,
        disabled = buttonDisabled
    }
end

function uiClass:onDisplayResized()
    self.phaseButton = nil
    self.surrenderButton = self:createDefaultSurrenderButton()
    self.unitCodexButton = nil
    self.uiElements = {}
    self.unitPositions = {}
    self.currentUIElementIndex = nil
    self.activeUIElement = nil
    self.lastPhaseButtonHover = false
    self.lastSurrenderButtonHover = false
    self.lastKeyboardFocusedButton = nil
    self.lastKeyboardFocusedPanel = nil
    self.hoveredSupplyFlipType = nil
    if type(self.clearOnlineReactionButtonsLayout) == "function" then
        self:clearOnlineReactionButtonsLayout()
    end
end

function uiClass:shouldHideAutomaticOnlinePhaseButton(phaseInfo, buttonInfo)
    if GAME.CURRENT.MODE ~= GAME.MODE.MULTYPLAYER_NET then
        return false
    end

    local currentPhase = tostring(phaseInfo and phaseInfo.currentPhase or "")
    local turnPhaseName = tostring(phaseInfo and phaseInfo.turnPhaseName or "")
    local actionType = tostring((buttonInfo and buttonInfo.actionType) or "")

    if actionType == "confirmCommandHub" then
        return false
    end

    if currentPhase == "setup" then
        return true
    end

    if currentPhase == "deploy1_units" or currentPhase == "deploy2_units" then
        return true
    end

    if currentPhase == "turn" and turnPhaseName == "actions" then
        return true
    end

    return false
end

function uiClass:shouldHideAutomaticSinglePlayerPhaseButton(phaseInfo, buttonInfo)
    local mode = GAME.CURRENT and GAME.CURRENT.MODE or nil
    if mode ~= GAME.MODE.SINGLE_PLAYER and mode ~= GAME.MODE.MULTYPLAYER_LOCAL then
        return false
    end

    local actionType = tostring((buttonInfo and buttonInfo.actionType) or "")
    if actionType == "confirmCommandHub" then
        return false
    end

    return true
end

function uiClass:calculateButtonAnimationValues(buttonX, buttonY)
    local buttonScale = 1
    local buttonOffset = 0
    local colorMod = 0

    -- Handle click animation
    if self.buttonAnimation.active and 
       self.buttonAnimation.x == buttonX and 
       self.buttonAnimation.y == buttonY then
        local progress = self.buttonAnimation.timer / self.buttonAnimation.duration
        if progress < 0.5 then
            buttonOffset = (progress * 2) * 3
            buttonScale = 1 - (progress * 2) * 0.03
            colorMod = (progress * 2) * -0.2
        else
            buttonOffset = (1 - (progress - 0.5) * 2) * 3
            buttonScale = 0.97 + (progress - 0.5) * 2 * 0.03
            colorMod = -0.2 + (progress - 0.5) * 2 * 0.2
        end
    elseif self.pulsing.active then
        -- Apply pulsing animation when no click animation is active
        buttonScale = self.pulsing.scale
    end

    return buttonScale, buttonOffset, colorMod
end

function uiClass:applyButtonScale(buttonX, buttonY, buttonWidth, buttonHeight, buttonScale)
    local centerX = buttonX + buttonWidth/2
    local centerY = buttonY + buttonHeight/2
    love.graphics.push()
    love.graphics.translate(centerX, centerY)
    love.graphics.scale(buttonScale, buttonScale)
    love.graphics.translate(-centerX, -centerY)
end

function uiClass:drawAnimatedArrow(x, y, size, player, isSupplyArrow)
    local time = love.timer.getTime()
    local pulse = math.sin(time * 10) * 3  -- Keep only the up-down pulse movement

    -- Get color (same logic as before)
    local arrowColor
    if isSupplyArrow then
        arrowColor = {1.0, 1.0, 1.0, 0.9}
    else
        local theme = self.playerThemes[player] or self.playerThemes[0]
        arrowColor = theme.highlight or {1, 1, 1}
    end

    -- Apply color and alpha
    love.graphics.setColor(arrowColor[1], arrowColor[2], arrowColor[3], arrowColor[4] or 0.9)

    local scaleX = size / self.uiArrowImage:getWidth()
    local scaleY = size / self.uiArrowImage:getHeight()

    -- Draw the PNG arrow with only up-down animation
    love.graphics.draw(
        self.uiArrowImage,
        x, y + pulse,  -- Position with pulse animation (up-down only)
        0,  -- rotation
        scaleX, scaleY,  -- scale (static size, no zoom)
        self.uiArrowImage:getWidth() / 2,   -- origin X (center)
        self.uiArrowImage:getHeight() / 2   -- origin Y (center)
    )

    -- Reset color
    love.graphics.setColor(1, 1, 1, 1)
end

function uiClass:drawSupplyUnitArrows(gameRuler)
    if not gameRuler then return end

    -- First, check if current player is AI and hide arrows if so
    if (GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and 
        gameRuler.currentPlayer == GAME.CURRENT.AI_PLAYER_NUMBER) or
       (GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI) then
        return
    end

    -- In online multiplayer, hide helper arrows when it's not the local player's turn.
    if self:isOnlineNonLocalTurn({currentPlayer = gameRuler.currentPlayer}) then
        return
    end

    if self.selectedUnit then
        return
    end

    if gameRuler.actionsPhaseSupplySelection then
        return
    end

    -- Only show arrows during actions phase deployment or initial deployment
    local showArrows = (gameRuler.currentPhase == "turn" and gameRuler.currentTurnPhase == "actions" and self.gameRuler:canDeployInActionsPhase()) or
                  ((gameRuler.currentPhase == "deploy1_units" and gameRuler.currentPlayer == 1) or
                   (gameRuler.currentPhase == "deploy2_units" and gameRuler.currentPlayer == 2))

    if not showArrows then
        return
    end

    -- Don't show arrows if already deployed this turn (actions phase)
    if gameRuler.currentPhase == "turn" and gameRuler.hasDeployedThisTurn then
        return
    end

    -- Hide arrows when a grid unit is selected for actions
    if gameRuler.currentActionPreview and gameRuler.currentActionPreview.selectedUnit then
        local selectedUnit = gameRuler.currentActionPreview.selectedUnit

        if selectedUnit.unit and 
           selectedUnit.unit.player == gameRuler.currentPlayer and
           not selectedUnit.unit.hasActed and
           selectedUnit.unit.name ~= "Commandant" then
            -- This is a current player's unit that can act - hide supply arrows
            return
        end
    end

    -- Don't show arrows during initial deployment if all required units are deployed
    if (gameRuler.currentPhase == "deploy1_units" or gameRuler.currentPhase == "deploy2_units") and
       gameRuler:isInitialDeploymentComplete() then
        return
    end

    -- Get current player's supply
    local playerSupply = nil
    if gameRuler.currentPlayer == 1 then
        playerSupply = self.playerSupply1
    else
        playerSupply = self.playerSupply2
    end

    -- No supply units, no arrows
    if not playerSupply or #playerSupply == 0 then
        return
    end

    -- Loop through unit positions to place arrows directly above each unit
    for _, unitPos in ipairs(self.unitPositions) do
        -- Only show arrow if there is a unit in this slot
        if unitPos.unit then
            local showArrowForUnit = false
            local slotOwner = unitPos.owner or unitPos.player

            if slotOwner then
                showArrowForUnit = slotOwner == gameRuler.currentPlayer
            end

            if showArrowForUnit then
                local arrowSize = 32  -- Smaller arrows
                local centerX = unitPos.x + unitPos.size / 2
                local arrowY = unitPos.y - 8  -- Position arrow above the unit

                self:drawAnimatedArrow(centerX, arrowY, arrowSize, 0, true)
            end
        end
    end
end

function uiClass:drawUnitActionArrows(gameRuler)
    if not gameRuler then return end

    -- First, check if current player is AI and hide arrows if so
    if (GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and 
        gameRuler.currentPlayer == GAME.CURRENT.AI_PLAYER_NUMBER) or
       (GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI) then
        return
    end

    -- In online multiplayer, hide helper arrows when it's not the local player's turn.
    if self:isOnlineNonLocalTurn({currentPlayer = gameRuler.currentPlayer}) then
        return
    end

    if self.selectedUnit then
        return
    end

    if gameRuler.actionsPhaseSupplySelection then
        return
    end

    -- Only draw arrows during action phase
    if gameRuler.currentPhase ~= "turn" or gameRuler.currentTurnPhase ~= "actions" then
        return
    end

    -- Hide arrows if there are any units currently animating
    local grid = gameRuler.currentGrid
    if grid and grid.movingUnits and #grid.movingUnits > 0 then
        return
    end

    -- Hide arrows if no actions are available
    if gameRuler:areActionsComplete() then
        return
    end

    local showArrows = true

    if gameRuler.currentActionPreview and gameRuler.currentActionPreview.selectedUnit then
        local selectedUnit = gameRuler.currentActionPreview.selectedUnit

        if selectedUnit.unit and 
           selectedUnit.unit.player == gameRuler.currentPlayer and
           not selectedUnit.unit.hasActed and
           selectedUnit.unit.name ~= "Commandant" then
            -- This is a current player's unit that can act
            showArrows = false
        else
            if not selectedUnit.unit then
                showArrows = true
            elseif selectedUnit.unit.player ~= gameRuler.currentPlayer then
                showArrows = true
            elseif selectedUnit.unit.player == 0 or selectedUnit.unit.name == "Rock" then
                showArrows = true
            end
        end
    end

    if not showArrows then
        return
    end

    -- Draw arrows only for units that haven't acted yet
    local arrowSize = 32
    local gridWidth = GAME.CONSTANTS.TILE_SIZE * GAME.CONSTANTS.GRID_SIZE
    local gridHeight = GAME.CONSTANTS.TILE_SIZE * GAME.CONSTANTS.GRID_SIZE
    local gridX = (SETTINGS.DISPLAY.WIDTH - gridWidth) / 2
    local gridY = (SETTINGS.DISPLAY.HEIGHT - gridHeight) / 2

    for row = 1, GAME.CONSTANTS.GRID_SIZE do
        for col = 1, GAME.CONSTANTS.GRID_SIZE do
            local cell = grid:getCell(row, col)

            if cell and cell.unit and 
               cell.unit.player == gameRuler.currentPlayer and not cell.unit.hasActed and
               cell.unit.name ~= "Commandant" then

                -- Check if unit has legal actions before showing arrow
                local hasLegalActions = gameRuler:unitHasLegalActions(row, col)
                if hasLegalActions then
                    local cellX = gridX + (col - 1) * GAME.CONSTANTS.TILE_SIZE
                    local cellY = gridY + (row - 1) * GAME.CONSTANTS.TILE_SIZE
                    local cellSize = GAME.CONSTANTS.TILE_SIZE

                    -- Use isSupplyArrow=true to get the same color as supply arrows
                    self:drawAnimatedArrow(
                        cellX + cellSize/2,
                        cellY - 15,
                        arrowSize,
                        gameRuler.currentPlayer,
                        true  -- Use the same tan/white color for all arrows
                    )
                end
            end
        end
    end
end

function uiClass:drawSupplyPanel(x, y, width, height, player, supplyArray)
    if not supplyArray then
        return
    end

    local panelData = self:getSupplyPanelData(player)
    local panelOwner = panelData.factionId or player
    local panelTheme = panelData.theme or self.playerThemes[panelOwner] or self.playerThemes[0]

    -- Determine if this player's supply panel should be highlighted
    local isDeploymentActive = false
    if self.gameRuler then
        local inDeploymentPhase =
            ( self.gameRuler.currentPhase == "turn"
            and self.gameRuler.currentTurnPhase == "actions"
            and self.gameRuler.currentPlayer == panelOwner
            and self.gameRuler:canDeployInActionsPhase()
            )
            or
            (self.gameRuler.currentPhase == "deploy1_units" and panelOwner == 1)
            or
            (self.gameRuler.currentPhase == "deploy2_units" and panelOwner == 2)

        if self.gameRuler.currentPhase == "deploy1_units" or self.gameRuler.currentPhase == "deploy2_units" then
            isDeploymentActive = inDeploymentPhase and not self.gameRuler:isInitialDeploymentComplete()
        else
            isDeploymentActive = inDeploymentPhase
        end
    end

    -- Determine which faction to use for coloring the units
    local displayFaction = panelData.factionId or panelOwner


    -- Create content drawing function to display supply units
    local contentDrawFunc = function(x, y, width, height, colors)
        -- Calculate grid layout
        local gridParams = self:calculateSupplyGridLayout(width, height)

        -- Store panel player number in grid params
        gridParams.panelPlayer = player

        -- Draw unit icons with adjusted positions for standardized panel
        self:drawSupplyUnitIconsStandard(x, y, width, height, supplyArray, displayFaction, gridParams)
    end

    local supplyPanelLabel = panelData.title

    -- Use the standardized panel drawing approach with isActive parameter
    self:drawStandardPanel(x, y, width, height, supplyPanelLabel, contentDrawFunc, isDeploymentActive, panelTheme)
end

function uiClass:calculateSupplyGridLayout(width, height)
    local gridCols = 4
    local gridRows = 4
    local iconSize = 48  -- Fixed size for bigger, consistent icons

    -- Calculate padding to center the grid within the panel
    local totalGridWidth = gridCols * iconSize + (gridCols - 1) * 6  -- 6px spacing between icons
    local totalGridHeight = gridRows * iconSize + (gridRows - 1) * 6  -- 6px spacing between icons

    local paddingX = math.max(6, (width - totalGridWidth) / 2)
    local paddingY = math.max(6, (height - 40 - totalGridHeight) / 2)  -- 40px for header

    return {
        cols = gridCols,
        rows = gridRows,
        padding = 6,  -- Fixed spacing between icons
        paddingX = paddingX -1,  -- Horizontal centering offset
        paddingY = paddingY,  -- Vertical centering offset
        iconSize = iconSize
    }
end

function uiClass:drawSupplyUnitIconsStandard(x, y, width, height, supplyArray, player, gridParams)
    local padding = gridParams.padding
    local paddingX = gridParams.paddingX
    local paddingY = gridParams.paddingY
    local iconSize = gridParams.iconSize
    local cols = gridParams.cols
    local rows = gridParams.rows

    -- Content starts below the horizontal separator line
    local startY = y + 36

    -- Draw chessboard pattern and units
    for row = 0, rows-1 do
        for col = 0, cols-1 do
            -- Calculate cell position using centering offsets
            local cellX = x + paddingX + col * (iconSize + padding)
            local cellY = startY + paddingY + row * (iconSize + padding)

            -- Determine if this is a "dark" or "light" square
            local isDarkSquare = (row + col) % 2 == 0

            -- Set color based on square type (matching main UI color scheme)
            if isDarkSquare then
                love.graphics.setColor(79/255, 62/255, 46/255, 0.4) -- Darker brown (matches UI highlight)
            else
                love.graphics.setColor(108/255, 88/255, 66/255, 0.25) -- Lighter brown (matches UI border)
            end

            -- Card background will be drawn by drawUnitIcon function

            -- Calculate a consistent cell index for ALL cells (filled or empty)
            local cellIndex = row * cols + col + 1
            local hasUnit = cellIndex <= #supplyArray

            -- Register all 16 cells for click detection, whether they have units or not
            table.insert(self.unitPositions, {
                x = cellX,
                y = cellY,
                size = iconSize,
                unit = hasUnit and supplyArray[cellIndex] or nil,
                player = player,
                panelPlayer = gridParams.panelPlayer,
                owner = self:getSupplyOwnerForPanel(gridParams.panelPlayer),
                index = cellIndex,
                isEmpty = not hasUnit
            })

            -- Draw unit if available
            if hasUnit then
                -- Draw the unit icon with consistent seed based on supply index
                self:drawSupplyUnitIcon(cellX, cellY, iconSize, supplyArray[cellIndex], player, cellIndex, false, false, false)
            end

            self:drawSelectionHighlight(cellX, cellY, iconSize, player, cellIndex)
        end
    end
end

function uiClass:drawSupplyUnitIcon(x, y, size, unit, player, supplyIndex, isHovered, isFocused, isSelected)
    -- Check if unit can fly
    local canFly = false
    if unit and unit.fly ~= nil then
        canFly = unit.fly
    end

    -- Determine which faction the icon should represent
    local iconFaction = player
    if GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL then
        if player == 1 then
            iconFaction = self.playerSupply1Faction or player
        elseif player == 2 then
            iconFaction = self.playerSupply2Faction or player
        end
    end
    
    -- Recurring, staggered gloss scheduling per icon (same direction for all)
    if not self.supplyOnceSched then
        self.supplyOnceSched = { sessionStart = love.timer.getTime(), icons = {} }
    end
    local schedKey = tostring(player or 0) .. ":" .. tostring(supplyIndex or 0)
    local sched = self.supplyOnceSched.icons[schedKey]
    if not sched then
        local baseDelay = 0.15 * (supplyIndex or 1)            -- small progressive base by index
        local jitter = math.random() * 0.8                      -- random initial jitter
        self.supplyOnceSched.icons[schedKey] = {
            nextAt = self.supplyOnceSched.sessionStart + baseDelay + jitter,
            startAt = 0,
            duration = 0,
            widthFrac = 0.12,
            dir = 1,     -- same direction for all
            running = false
        }
        sched = self.supplyOnceSched.icons[schedKey]
    end
    
    -- Draw card template first to get dimensions
    if self.cardTemplateImage then
        -- Calculate scaling to fit the card to the icon size
        local cardWidth = self.cardTemplateImage:getWidth()
        local cardHeight = self.cardTemplateImage:getHeight()
        local cardScale = math.min(size / cardWidth, size / cardHeight)
        
        -- Calculate card position (same as used for drawing the template)
        local cardX = x + 1 + (size - cardWidth * cardScale) / 2
        local cardY = y - 1 + (size - cardHeight * cardScale) / 2
        
        -- Draw animated gradient background based on unit type
        local bgHeight = cardHeight * cardScale - 2
        local bgWidth = cardWidth * cardScale - 2
        local bgY = cardY + 2  -- Center the reduced height background
        
        -- Add gentle animation
        local time = love.timer.getTime()
        local pulse = math.sin(time * 1.5 + supplyIndex * 0.7) * 0.08 + 0.92
        
        if canFly then
            -- Animated sky gradient for flying units
            love.graphics.setColor(0.6 * pulse, 0.8 * pulse, 1.0, 1.0)
            love.graphics.rectangle("fill", cardX, bgY, bgWidth, bgHeight)
            
            -- Add animated top highlight with shimmer
            local shimmer = math.sin(time * 2.2 + supplyIndex * 0.5) * 0.15 + 0.7
            love.graphics.setColor(0.85, 0.95, 1.0, shimmer)
            love.graphics.rectangle("fill", cardX, bgY, bgWidth, bgHeight * 0.4)
            
            -- Add gently moving cloud shadow
            local cloudShift = math.sin(time * 0.8 + supplyIndex) * 0.1 + 0.5
            love.graphics.setColor(0.5, 0.7, 0.9, cloudShift)
            love.graphics.rectangle("fill", cardX, bgY + bgHeight * 0.6, bgWidth, bgHeight * 0.4)

        else
            -- Animated grass gradient for ground units
            love.graphics.setColor(0.4 * pulse, 0.65 * pulse, 0.3 * pulse, 1.0)
            love.graphics.rectangle("fill", cardX, bgY, bgWidth, bgHeight)
            
            -- Add swaying grass highlight
            local grassSway = math.sin(time * 1.8 + supplyIndex * 0.4) * 0.12 + 0.7
            love.graphics.setColor(0.5, 0.8, 0.35, grassSway)
            love.graphics.rectangle("fill", cardX, bgY, bgWidth, bgHeight * 0.5)
            
            -- Add breathing earth bottom
            local earthBreath = math.sin(time * 1.1 + supplyIndex * 0.6) * 0.1 + 0.6
            love.graphics.setColor(0.3, 0.5, 0.2, earthBreath)
            love.graphics.rectangle("fill", cardX, bgY + bgHeight * 0.7, bgWidth, bgHeight * 0.3)

            -- (moved the sweep band to render AFTER the unit image so it appears on top)
        end
        
        -- Apply color tinting based on player (match faction screen tints)
        local tintPlayer = iconFaction

        if tintPlayer == 1 then
            love.graphics.setColor(0.2, 0.4, 0.8, 0.8)
        elseif tintPlayer == 2 then
            love.graphics.setColor(0.8, 0.2, 0.2, 0.8)
        else
            love.graphics.setColor(1, 1, 1, 1)
        end
        
        -- Generate random flipping based on supply index (consistent with info panel)
        local seed = supplyIndex * 1000 + (tintPlayer or 1) * 100
        local flipType = randomGen.deterministicRandom(seed, 1, 4)
        
        -- Calculate flip scales
        local scaleX = cardScale
        local scaleY = cardScale
        local offsetX = 0
        local offsetY = 0
        
        if flipType == 2 or flipType == 4 then  -- Horizontal flip
            scaleX = -cardScale
            offsetX = cardWidth * cardScale
        end
        if flipType == 3 or flipType == 4 then  -- Vertical flip
            scaleY = -cardScale
            offsetY = cardHeight * cardScale
        end
        
        -- Center the card background
        local cardX = x + (size - cardWidth * cardScale) / 2 + offsetX
        local cardY = y + (size - cardHeight * cardScale) / 2 + offsetY
        
        love.graphics.draw(self.cardTemplateImage, cardX, cardY, 0, scaleX, scaleY)
    end

    local unitImage = self:getUnitImage(unit, iconFaction)

    if unitImage then
        -- No color tinting needed - sprites already have correct faction colors
        love.graphics.setColor(1, 1, 1, 1)

        -- Calculate scaling to fit the icon size (slightly smaller to fit on card) with zoom
        local imageWidth = unitImage:getWidth()
        local imageHeight = unitImage:getHeight()
        local scale = math.min(size / imageWidth, size / imageHeight) * 0.8

        -- Center the image in the icon area
        local imageX = x + (size - imageWidth * scale) / 2
        local imageY = y + (size - imageHeight * scale) / 2

        -- Apply zoom effect if hovered
        if isHovered then
            scale = scale * 1.3  -- 30% zoom for unit icons
            imageX = x + (size - imageWidth * scale) / 2
            imageY = y + (size - imageHeight * scale) / 2
        end

        -- Flip unit images horizontally for both factions
        love.graphics.draw(unitImage, imageX + imageWidth * scale, imageY, 0, -scale, scale)
    end

    -- Overlay diagonal sweep band clipped to the card template area (on top of unit image)
    if self.cardTemplateImage and sched then
        -- Recompute card metrics locally so we don't rely on previous scope
        local cardWidth = self.cardTemplateImage:getWidth()
        local cardHeight = self.cardTemplateImage:getHeight()
        local cardScale = math.min(size / cardWidth, size / cardHeight)
        local cardX = x + 1 + (size - cardWidth * cardScale) / 2
        local cardY = y - 1 + (size - cardHeight * cardScale) / 2

        -- Card background rect and rounded mask
        local bgHeight = cardHeight * cardScale - 2
        local bgWidth = cardWidth * cardScale - 2
        local bgY = cardY + 2
        local inset = math.max(1, math.min(bgWidth, bgHeight) * 0.06)
        local maskX = cardX + inset
        local maskY = bgY + inset
        local maskW = bgWidth - inset * 2
        local maskH = bgHeight - inset * 2
        local radius = math.min(maskW, maskH) * 0.12

        -- Stencil in local (transformed) space so it follows resizing/scale
        love.graphics.stencil(function()
            love.graphics.rectangle("fill", maskX, maskY, maskW, maskH, radius, radius)
        end, "replace", 1)
        love.graphics.setStencilTest("greater", 0)

        local cx = cardX + bgWidth/2
        local cy = bgY + bgHeight/2
        local angle = canFly and math.rad(22) or math.rad(18)
        local diag = math.sqrt(bgWidth*bgWidth + bgHeight*bgHeight)
        local now = love.timer.getTime()
        -- If not running and it's time, schedule a new pass with randomized params
        if not sched.running and now >= (sched.nextAt or 0) then
            sched.duration = 0.9 + math.random() * 0.8   -- 0.9..1.7s
            sched.widthFrac = 0.10 + math.random() * 0.05 -- 0.10..0.15
            sched.startAt = now
            sched.running = true
        end

        if sched.running then
            local t = (now - sched.startAt) / (sched.duration > 0 and sched.duration or 1)
            if t >= 0 and t <= 1 then
                local bandW = math.max(4, bgWidth * sched.widthFrac)
                local span = (bgWidth + bandW)
                local rx = -span/2 + span * t  -- same direction for all (left -> right)

                local prevBlend, prevAlpha = love.graphics.getBlendMode()
                love.graphics.setBlendMode("add", "alphamultiply")
                love.graphics.push()
                love.graphics.translate(cx, cy)
                love.graphics.rotate(angle)
                -- Smooth fade in/out
                local alphaMul = math.sin(t * math.pi)
                if canFly then
                    love.graphics.setColor(0.95, 0.98, 1.0, 0.10 * alphaMul)
                else
                    love.graphics.setColor(0.95, 1.0, 0.85, 0.08 * alphaMul)
                end
                love.graphics.rectangle("fill", rx - bandW/2, -diag, bandW, diag*2)
                love.graphics.pop()
                love.graphics.setBlendMode(prevBlend, prevAlpha)
            else
                -- Finished a pass; schedule next after a random cooldown
                sched.running = false
                sched.nextAt = now + (0.6 + math.random() * 1.6)  -- 0.6..2.2s
            end
        end
        love.graphics.setStencilTest()
    end
end

function uiClass:drawSelectionHighlight(x, y, size, player, index)
    local showIndicator = false
    local indicatorAlpha = 0.9

    -- Check if this unit is selected via UI
    if self.selectedUnitPlayer == player and self.selectedUnitIndex == index and self.selectedUnit then
        showIndicator = true
        indicatorAlpha = 0.9  -- Full opacity for selected
    -- Check if this unit is hovered (and not selected)
    elseif self.hoveredUnitPlayer == player and self.hoveredUnitIndex == index and 
           not (self.selectedUnitPlayer == player and self.selectedUnitIndex == index and self.selectedUnit) then
        showIndicator = true
        indicatorAlpha = 0.6  -- Lower opacity for hover
    end


    if self.gameRuler and self.gameRuler.actionsPhaseSupplySelection == index and
       self.gameRuler.currentPlayer == player and
       self.gameRuler.actionsPhaseSupplySelection ~= nil then
        showIndicator = true
        indicatorAlpha = 0.9  -- Full opacity for gameRuler selection
    end

    if showIndicator and self.uiSelectionPointerImage then
        local indicatorColor = {1.0, 1.0, 1.0, indicatorAlpha}

        -- Calculate indicator position and size - LARGER than unit icon
        local indicatorSize = size * 1.2  -- 20% larger than the unit icon
        local centerX = x + size / 2
        local centerY = y + size / 2

        -- Apply white color and alpha
        love.graphics.setColor(indicatorColor[1], indicatorColor[2], indicatorColor[3], indicatorColor[4])

        -- Draw the PNG indicator (static, no animation)
        love.graphics.draw(
            self.uiSelectionPointerImage,
            centerX, centerY,
            0, -- rotation
            indicatorSize / self.uiSelectionPointerImage:getWidth(),
            indicatorSize / self.uiSelectionPointerImage:getHeight(),
            self.uiSelectionPointerImage:getWidth() / 2,  -- origin X (center)
            self.uiSelectionPointerImage:getHeight() / 2   -- origin Y (center)
        )

        -- Reset color
        love.graphics.setColor(1, 1, 1, 1)
    end
end

function uiClass:clearSupplySelection()
    self.selectedUnit = nil
    self.selectedUnitIndex = nil
    self.selectedUnitPlayer = nil
    self.selectedUnitCoordOnPanel = nil
    self.hoveredUnitPlayer = nil
    self.hoveredUnitIndex = nil
    self.selectedSource = nil
end

function uiClass:drawGameOverButton(x, buttonY)
    local button = self.gameOverPanel.button
    local buttonX = x + (self.gameOverPanel.width - button.width) / 2

    -- Store button position
    button.x = buttonX
    button.y = buttonY

    -- Ensure consistent colors during keyboard navigation: only focused button uses hover color
    if self.uIkeyboardNavigationActive and self.navigationMode == "ui" then
        if self.activeUIElement and self.activeUIElement.name == "mainMenuButton" then
            button.currentColor = button.hoverColor
        else
            button.currentColor = self.colors.button
        end
    end
    -- Draw using the currentColor
    love.graphics.setColor(button.currentColor)
    love.graphics.rectangle("fill", buttonX, buttonY, button.width, button.height, 8, 8)

    -- Button border - only emphasize when hovered/focused
    local isMouseHovered = (not (self.uIkeyboardNavigationActive and self.navigationMode == "ui")) and (button.currentColor == button.hoverColor)
    local isKeyboardFocused = (self.uIkeyboardNavigationActive and self.activeUIElement and 
                              self.activeUIElement.name == "mainMenuButton")

    if isMouseHovered or isKeyboardFocused then
        love.graphics.setColor(255/255, 240/255, 220/255, 0.8)
        love.graphics.setLineWidth(2.5)
    else
        local border = self.colors.border
        love.graphics.setColor(border[1], border[2], border[3], border[4] or 1)
        love.graphics.setLineWidth(2)
    end
    love.graphics.rectangle("line", buttonX, buttonY, button.width, button.height, 8, 8)
    love.graphics.setLineWidth(1)

    -- Inner accent line only when focused/hovered
    if isMouseHovered or isKeyboardFocused then
        local accent = uiTheme.lighten(self.colors.highlight, 0.3)
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.35)
        love.graphics.rectangle("line", buttonX + 3, buttonY + 3, button.width - 6, button.height - 6, 6, 6)
    end

    -- Button text with shadow
    local shadowColor = uiTheme.darken(self.colors.text, 0.6)
    love.graphics.setColor(shadowColor[1], shadowColor[2], shadowColor[3], 0.7)
    love.graphics.printf(button.text, buttonX + 1, buttonY + 16, button.width, "center")

    local textColor = self.colors.text
    love.graphics.setColor(textColor[1], textColor[2], textColor[3], textColor[4] or 1)
    love.graphics.printf(button.text, buttonX, buttonY + 15, button.width, "center")
end

function uiClass:drawWinnerSection(x, y)
    local width = self.gameOverPanel.width
    local winner = self.gameRuler.winner or "Unknown"

    local bannerWidth = 380
    local bannerHeight = 60
    local bannerX = x + (width - bannerWidth) / 2

    local winnerText = "Player " .. winner .. " Wins!"
    local winnerName = nil

    local playerColors = {
        [1] = uiTheme.COLORS.blueTeam,
        [2] = uiTheme.COLORS.redTeam
    }

    local winnerIndex
    if type(winner) == "number" then
        winnerIndex = winner > 0 and winner or nil
    elseif type(winner) == "string" then
        local parsed = tonumber(winner)
        if parsed and parsed > 0 then
            winnerIndex = parsed
        end
    end

    local baseWinnerColor = playerColors[winnerIndex] or uiTheme.lighten(self.colors.highlight, 0.25)

    if winner == 0 then
        winnerText = "GAME DRAW"
        baseWinnerColor = uiTheme.lighten(self.colors.highlight, 0.25)
    else
        if winnerIndex then
            winnerName = self:getFactionDisplayName(winnerIndex, "Player " .. tostring(winnerIndex))
        end

        if GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and winner == GAME.CURRENT.AI_PLAYER_NUMBER then
            winnerText = "AI Victory"
        elseif GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI then
            winnerText = "AI " .. winner .. " Victorious"
        elseif winnerName and winnerName ~= "" then
            winnerText = winnerName .. " Wins!"
        end
    end

    local bannerFill = uiTheme.darken(baseWinnerColor, 0.5)
    local bannerBorder = uiTheme.darken(baseWinnerColor, 0.25)
    local textColor = uiTheme.lighten(baseWinnerColor, 0.3)

    love.graphics.setColor(bannerFill[1], bannerFill[2], bannerFill[3], 0.9)
    love.graphics.rectangle("fill", bannerX, y, bannerWidth, bannerHeight, 12, 12)

    love.graphics.setLineWidth(2)
    love.graphics.setColor(bannerBorder[1], bannerBorder[2], bannerBorder[3], 1)
    love.graphics.rectangle("line", bannerX, y, bannerWidth, bannerHeight, 12, 12)
    love.graphics.setLineWidth(1)

    local defaultFont = love.graphics.getFont()
    local winnerFont = getMonogramFont(SETTINGS.FONT.BIG_SIZE + 6)
    love.graphics.setFont(winnerFont)

    local gold = {0.92, 0.82, 0.55, 1}
    local textY = y + (bannerHeight - winnerFont:getHeight()) / 2
    love.graphics.setColor(gold)
    love.graphics.printf(winnerText, x, textY, width, "center")

    love.graphics.setFont(defaultFont)
end

function uiClass:resetConfetti()
    if not self.gameOverPanel then return end
    if self.gameOverPanel.confettiParticles then
        for _, particle in ipairs(self.gameOverPanel.confettiParticles) do
            table.insert(self.gameOverPanel.confettiPool, particle)
        end
    end
    self.gameOverPanel.confettiParticles = {}
    self.gameOverPanel.confettiActive = false
    self.gameOverPanel.confettiSpawned = false
end

local function acquireConfettiParticle(panel)
    if #panel.confettiPool > 0 then
        local particle = panel.confettiPool[#panel.confettiPool]
        panel.confettiPool[#panel.confettiPool] = nil
        return particle
    end
    return {}
end

function uiClass:spawnConfettiBurst()
    if not self.gameOverPanel or self.gameOverPanel.confettiSpawned then return end

    local panel = self.gameOverPanel
    local panelX = (SETTINGS.DISPLAY.WIDTH - panel.width) / 2
    local panelY = panel.currentY
    local screenWidth = SETTINGS.DISPLAY.WIDTH
    local screenHeight = SETTINGS.DISPLAY.HEIGHT

    local colors = {
        {0.95, 0.86, 0.55, 1},
        uiTheme.lighten(self.colors.highlight, 0.45),
        uiTheme.lighten(uiTheme.COLORS.blueTeam, 0.35),
        uiTheme.lighten(uiTheme.COLORS.redTeam, 0.35),
        {0.95, 0.68, 0.3, 1}
    }

    panel.confettiParticles = {}

    local total = 260
    for i = 1, total do
        local color = colors[((i - 1) % #colors) + 1]
        local life = 2.6 + math.random() * 1.1
        local fromLeft = i <= total / 2

        local startX
        local vx

        if fromLeft then
            startX = -60 + math.random() * 80
            vx = 210 + math.random() * 210
        else
            startX = screenWidth - 20 - math.random() * 80
            vx = -(210 + math.random() * 210)
        end

        local startY = screenHeight + math.random() * 40
        local vy = -(560 + math.random() * 250)

        local particle = {
            x = startX,
            y = startY,
            vx = vx,
            vy = vy,
            life = life,
            maxLife = life,
            rotation = math.random() * math.pi,
            spin = (math.random() - 0.5) * 6,
            size = 6 + math.random() * 6,
            shape = (math.random() > 0.5) and "rect" or "tri",
            color = color
        }
        table.insert(panel.confettiParticles, particle)
    end

    panel.confettiActive = true
    panel.confettiSpawned = true

    local yayVolume = math.max(0, (SETTINGS.AUDIO.SFX_VOLUME or 1) - 0.2)
    self:playUISound(self.victoryYaySoundPath, yayVolume)
end

function uiClass:updateConfetti(dt)
    if not self.gameOverPanel or not self.gameOverPanel.confettiActive then return end

    local particles = self.gameOverPanel.confettiParticles
    local gravity = 340
    local panelX = (SETTINGS.DISPLAY.WIDTH - self.gameOverPanel.width) / 2

    for i = #particles, 1, -1 do
        local p = particles[i]
        p.vy = p.vy + gravity * dt
        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt
        p.rotation = p.rotation + p.spin * dt
        p.life = p.life - dt

        if p.life <= 0 or p.y < self.gameOverPanel.currentY - 720 or
           p.x < panelX - 320 or p.x > panelX + self.gameOverPanel.width + 320 then
            table.remove(particles, i)
        end
    end

    if #particles == 0 then
        self.gameOverPanel.confettiActive = false
    end
end

function uiClass:drawConfetti()
    if not self.gameOverPanel or not self.gameOverPanel.confettiActive then return end

    for _, p in ipairs(self.gameOverPanel.confettiParticles) do
        local alpha = (p.color[4] or 1) * math.max(p.life / p.maxLife, 0)
        love.graphics.setColor(p.color[1], p.color[2], p.color[3], alpha)
        love.graphics.push()
        love.graphics.translate(p.x, p.y)
        love.graphics.rotate(p.rotation)
        if p.shape == "rect" then
            love.graphics.rectangle("fill", -p.size / 2, -p.size / 2, p.size, p.size * 0.6, 2, 2)
        else
            love.graphics.polygon("fill",
                0, -p.size * 0.6,
                p.size * 0.5, p.size * 0.4,
                -p.size * 0.5, p.size * 0.4
            )
        end
        love.graphics.pop()
    end

    love.graphics.setColor(1, 1, 1, 1)
end

function uiClass:drawGameStatistics(x, y)
    local stats = self.gameRuler.gameStats
    local panelWidth = self.gameOverPanel.width
    local contentWidth = panelWidth - 80
    local lineHeight = 24
    local statsY = y

    -- Create a two-column layout for statistics
    local leftColX = x + 56
    local rightColX = x + panelWidth/2 + 8
    local colWidth = (contentWidth / 2) - 30

    local textColor = self.colors.text
    local mutedText = uiTheme.darken(self.colors.text, 0.35)
    local headerColor = uiTheme.lighten(self.colors.highlight, 0.25)
    local accentColor = uiTheme.lighten(self.colors.highlight, 0.1)
    local playerOneAccent = uiTheme.lighten(uiTheme.COLORS.blueTeam, 0.25)
    local playerTwoAccent = uiTheme.lighten(uiTheme.COLORS.redTeam, 0.25)
    local playerOneBase = uiTheme.COLORS.blueTeam
    local playerTwoBase = uiTheme.COLORS.redTeam

    -- === SECTION 1: MATCH OVERVIEW (More compact) ===
    love.graphics.setColor(headerColor[1], headerColor[2], headerColor[3], 1)
    love.graphics.printf("MATCH OVERVIEW", x, statsY, panelWidth, "center")
    statsY = statsY + lineHeight

    -- Draw background panel
    self:drawStatSectionBackground(leftColX - 16, statsY, contentWidth, lineHeight * 3) -- Increased height for more stats

    -- Match duration and turn count
    love.graphics.setColor(mutedText[1], mutedText[2], mutedText[3], mutedText[4] or 0.9)
    love.graphics.print("GAME TIME:", leftColX, statsY + 10)

    local minutes = math.floor(self.gameRuler.gameTimer.totalGameTime / 60)
    local seconds = math.floor(self.gameRuler.gameTimer.totalGameTime % 60)
    love.graphics.setColor(textColor[1], textColor[2], textColor[3], textColor[4] or 0.9)
    love.graphics.print(string.format("%d:%02d", minutes, seconds), leftColX + 112, statsY + 10)

    local p1DisplayName = self:truncateDisplayName(self:getFactionDisplayName(1, "Player 1"), 16)
    local p2DisplayName = self:truncateDisplayName(self:getFactionDisplayName(2, "Player 2"), 16)

    -- Player 1 time
    love.graphics.setColor(mutedText[1], mutedText[2], mutedText[3], mutedText[4] or 0.9)
    love.graphics.print(string.upper(p1DisplayName) .. " TIME:", (rightColX - 10) + 212, statsY + 10)
    local p1Minutes = math.floor(self.gameRuler.gameTimer.playerTime[1] / 60)
    local p1Seconds = math.floor(self.gameRuler.gameTimer.playerTime[1] % 60)
    love.graphics.setColor(playerOneAccent[1], playerOneAccent[2], playerOneAccent[3], 0.9)
    love.graphics.print(string.format("%d:%02d", p1Minutes, p1Seconds), (rightColX - 10) + 352, statsY + 10)

    -- Player 2 time
    love.graphics.setColor(mutedText[1], mutedText[2], mutedText[3], mutedText[4] or 0.9)
    love.graphics.print(string.upper(p2DisplayName) .. " TIME:", (rightColX - 10) + 212, statsY + 34)
    local p2Minutes = math.floor(self.gameRuler.gameTimer.playerTime[2] / 60)
    local p2Seconds = math.floor(self.gameRuler.gameTimer.playerTime[2] % 60)
    love.graphics.setColor(playerTwoAccent[1], playerTwoAccent[2], playerTwoAccent[3], 0.9)
    love.graphics.print(string.format("%d:%02d", p2Minutes, p2Seconds), (rightColX - 10) + 352, statsY + 34)

    love.graphics.setColor(mutedText[1], mutedText[2], mutedText[3], mutedText[4] or 0.9)
    love.graphics.print("PLAYED TURNS:", leftColX, statsY + 34)
    love.graphics.setColor(textColor[1], textColor[2], textColor[3], textColor[4] or 0.9)
    -- Use currentTurn instead of stats.turns to show the actual turn count when game ended
    love.graphics.print(tostring(self.gameRuler.currentTurn), leftColX + 112, statsY + 34)

    -- MVP and Rocks
    love.graphics.setColor(mutedText[1], mutedText[2], mutedText[3], mutedText[4] or 0.9)
    love.graphics.print("UNITS TYPE MVP:", leftColX + 308, statsY + 10)
    love.graphics.setColor(accentColor[1], accentColor[2], accentColor[3], 0.95)

    -- Rest of the function remains unchanged
    local mvpText = stats.mostEffectiveUnit or "None"
    love.graphics.print(mvpText, leftColX + 468, statsY + 10)

    love.graphics.setColor(mutedText[1], mutedText[2], mutedText[3], mutedText[4] or 0.9)
    love.graphics.print("ROCKS DESTROYED:", leftColX + 308, statsY + 34)
    love.graphics.setColor(textColor[1], textColor[2], textColor[3], textColor[4] or 0.9)
    love.graphics.print(stats.neutralBuildingsDestroyed, leftColX + 468, statsY + 34)

    -- Update Y position (adjusted for added player time stats)
    statsY = statsY + lineHeight * 4

    -- === SECTION 2: PLAYER COMPARISON HEADERS ===
    local p1Label = self:truncateDisplayName(self:getFactionDisplayName(1, "Player 1"), 22)
    local p2Label = self:truncateDisplayName(self:getFactionDisplayName(2, "Player 2"), 22)

    love.graphics.setColor(headerColor[1], headerColor[2], headerColor[3], 1)
    love.graphics.printf("NERD STATS", x, statsY, panelWidth, "center")
    statsY = statsY + lineHeight

    -- Player column headers with colored backgrounds
    self:drawPlayerHeader(leftColX, statsY, colWidth, p1Label, playerOneBase)
    self:drawPlayerHeader(rightColX, statsY, colWidth, p2Label, playerTwoBase)
    statsY = statsY + lineHeight * 1.2

    -- === SECTION 3: COMBINED STATISTICS ===
    -- Draw background panel for all stats
    self:drawStatSectionBackground(leftColX - 20, statsY + 4, contentWidth, lineHeight * 13)

    -- Combat stats
    love.graphics.setColor(headerColor[1], headerColor[2], headerColor[3], 1)
    love.graphics.printf("COMBAT", leftColX - 20, statsY + 9, contentWidth, "center")
    statsY = statsY + lineHeight + 5

    self:drawStatComparison(leftColX, rightColX - 10, statsY, "TOTAL DAMAGE DEALT:", 
        stats.players[1].damageDealt, stats.players[2].damageDealt)
    statsY = statsY + lineHeight

    self:drawStatComparison(leftColX, rightColX - 10, statsY, "TOTAL DAMAGE TAKEN:", 
        stats.players[1].damageTaken, stats.players[2].damageTaken)
    statsY = statsY + lineHeight

    self:drawStatComparison(leftColX, rightColX - 10, statsY, "UNITS DESTROYED:", 
        stats.players[1].unitsDestroyed, stats.players[2].unitsDestroyed)
    statsY = statsY + lineHeight * 1.2

    -- Deployment stats (continuing in same panel)
    love.graphics.setColor(headerColor[1], headerColor[2], headerColor[3], 1)
    love.graphics.line(leftColX, statsY - 5, rightColX + colWidth - 20, statsY - 5)
    love.graphics.printf("DEPLOYMENT", leftColX - 20, statsY + 4, contentWidth, "center")
    statsY = statsY + lineHeight + 5

    self:drawStatComparison(leftColX, rightColX - 10, statsY, "UNITS DEPLOYED:", 
        stats.players[1].unitsDeployed, stats.players[2].unitsDeployed)
    statsY = statsY + lineHeight

    self:drawStatComparison(leftColX, rightColX - 10, statsY, "UNITS LOST:", 
        stats.players[1].unitsLost, stats.players[2].unitsLost)
    statsY = statsY + lineHeight * 1.2

    -- Efficiency stats (continuing in same panel)
    love.graphics.setColor(headerColor[1], headerColor[2], headerColor[3], 1)
    love.graphics.line(leftColX, statsY - 5, rightColX + colWidth - 20, statsY - 5)
    love.graphics.printf("EFFICIENCY", leftColX - 20, statsY + 4, contentWidth, "center")
    statsY = statsY + lineHeight + 5

    self:drawStatComparison(leftColX, rightColX - 10, statsY, "REPAIR ACTIONS:", 
        stats.players[1].repairPoints or 0, stats.players[2].repairPoints or 0)
        statsY = statsY + lineHeight

    self:drawStatComparison(leftColX, rightColX - 10, statsY, "HUB ASSAULT TAKEN:", 
            stats.players[1].commandHubAttacksSurvived or 0, 
            stats.players[2].commandHubAttacksSurvived or 0)
            statsY = statsY + lineHeight

    self:drawStatComparison(leftColX, rightColX - 10, statsY, "HUB ASSAULT TAKEN:", 
    stats.players[1].commandHubAttacksSurvived or 0, 
    stats.players[2].commandHubAttacksSurvived or 0)
    statsY = statsY + lineHeight

    -- At the end, ensure we return the true final Y position
    local finalY = statsY + (lineHeight * 1.5)

    return finalY + 10  -- Add padding to ensure separation from button
end

-- Helper function to draw consistent stat section backgrounds
function uiClass:drawStatSectionBackground(x, y, width, height)
    local base = uiTheme.darken(self.colors.background, 0.15)
    love.graphics.setColor(base[1], base[2], base[3], 0.85)
    love.graphics.rectangle("fill", x, y, width, height, 6, 6)

    local border = self.colors.border
    love.graphics.setColor(border[1], border[2], border[3], border[4] or 1)
    love.graphics.rectangle("line", x, y, width, height, 6, 6)
end

-- Helper function to draw player column headers
function uiClass:drawPlayerHeader(x, y, width, text, color)
    local base = uiTheme.darken(color, 0.35)
    love.graphics.setColor(base[1], base[2], base[3], 0.9)
    love.graphics.rectangle("fill", x, y, width, 24, 5, 5)

    local border = uiTheme.lighten(color, 0.15)
    love.graphics.setColor(border[1], border[2], border[3], 0.9)
    love.graphics.setLineWidth(1.5)
    love.graphics.rectangle("line", x, y, width, 24, 5, 5)
    love.graphics.setLineWidth(1)

    local accent = uiTheme.lighten(color, 0.3)
    love.graphics.setColor(accent[1], accent[2], accent[3], 0.4)
    love.graphics.rectangle("line", x + 2, y + 2, width - 4, 20, 4, 4)

    local shadow = uiTheme.darken(self.colors.text, 0.7)
    love.graphics.setColor(shadow[1], shadow[2], shadow[3], 0.8)
    local textWidth = love.graphics.getFont():getWidth(text)
    love.graphics.print(text, x + (width - textWidth)/2 + 1, y + 4)

    local textColor = self.colors.text
    love.graphics.setColor(textColor[1], textColor[2], textColor[3], textColor[4] or 0.95)
    love.graphics.print(text, x + (width - textWidth)/2, y + 3)
end

-- Helper function to draw stat comparisons
function uiClass:drawStatComparison(leftX, rightX, y, label, leftValue, rightValue)
    local labelWidth = 218
    local textX = leftX
    local labelColor = uiTheme.darken(self.colors.text, 0.25)
    love.graphics.setColor(labelColor[1], labelColor[2], labelColor[3], labelColor[4] or 0.9)
    love.graphics.print(label, textX + 88, y)
    love.graphics.print(label, textX + 550, y)

    local p1ValueColor = self.colors.text
    local p2ValueColor = self.colors.text

    if type(leftValue) == "number" and type(rightValue) == "number" then
        if leftValue > rightValue then
            p1ValueColor = uiTheme.lighten(uiTheme.COLORS.blueTeam, 0.25)
        elseif rightValue > leftValue then
            p2ValueColor = uiTheme.lighten(uiTheme.COLORS.redTeam, 0.25)
        end
    end

    love.graphics.setColor(p1ValueColor[1], p1ValueColor[2], p1ValueColor[3], 0.95)
    love.graphics.print(tostring(leftValue), leftX + 88 + labelWidth, y)

    love.graphics.setColor(p2ValueColor[1], p2ValueColor[2], p2ValueColor[3], 0.95)
    love.graphics.print(tostring(rightValue), leftX + 550 + labelWidth, y)
end

function uiClass:drawGameOverPanel()
    if not self.gameRuler or self.gameRuler.currentPhase ~= "gameOver" then return end

    -- If panel is hidden, only show the "Return to Results" button
    if not self.gameOverPanel.visible then
        self:drawReturnToResultsButton()
        return
    end

    -- Calculate panel position
    local panelX = (SETTINGS.DISPLAY.WIDTH - self.gameOverPanel.width) / 2
    local panelY = self.gameOverPanel.currentY

    -- Create darkened background using theme colors
    local overlayColor = uiTheme.darken(self.colors.background, 0.4)
    love.graphics.setColor(overlayColor[1], overlayColor[2], overlayColor[3], 0.85)
    love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)

    -- Soft shadow around the panel
    love.graphics.setColor(0, 0, 0, 0.35)
    love.graphics.rectangle("fill", panelX - 8, panelY - 8, self.gameOverPanel.width + 16, self.gameOverPanel.height + 16, 12, 12)

    -- Draw panel background
    self:drawPanelWithGradient(panelX, panelY, self.gameOverPanel.width, self.gameOverPanel.height)

    if self.gameOverPanel.currentY >= self.gameOverPanel.targetY - self.gameOverPanel.height and not self.gameOverPanel.confettiSpawned then
        self:spawnConfettiBurst()
    end

    -- Draw title and winner sections
    self:drawGameOverTitle(panelX, panelY)
    self:drawWinnerSection(panelX, panelY + 70)
    self:drawDecorativeSeparator(panelX + 40, panelY + 145, self.gameOverPanel.width - 80)

    -- Draw statistics and get the final Y position
    local finalStatsY = self:drawGameStatistics(panelX, panelY + 165)

    -- Add a fixed buffer space to ensure button is separated from content
    local buttonY = finalStatsY

    -- Ensure button is not positioned below panel bottom
    if buttonY > panelY + self.gameOverPanel.height - 70 then
        -- If we need more space, increase panel height dynamically
        self.gameOverPanel.height = (buttonY - panelY) + 70
    end

    -- Draw return to menu button at calculated position
    self:drawGameOverButton(panelX, buttonY)

    -- Draw the toggle button (to show battlefield) left of the main button
    self:drawToggleButton(panelX - 256, buttonY)

    self:drawConfetti()
end

function uiClass:drawToggleButton(x, y)
    local button = self.gameOverPanel.toggleButton
    local width = 220
    local height = 50
    local buttonX = x + (self.gameOverPanel.width - width) / 2
    
    -- Update button properties
    button.x = buttonX
    button.y = y
    button.width = width
    button.height = height
    
    -- Ensure consistent colors during keyboard navigation: only focused button uses hover color
    if self.uIkeyboardNavigationActive and self.navigationMode == "ui" then
        if self.activeUIElement and self.activeUIElement.name == "toggleButton" then
            button.currentColor = button.hoverColor
        else
            button.currentColor = self.colors.button
        end
    end
    -- Draw using the currentColor
    love.graphics.setColor(button.currentColor)
    love.graphics.rectangle("fill", buttonX, y, width, height, 8, 8)
    
    -- Button border - only emphasize when hovered/focused
    local isMouseHovered = (not (self.uIkeyboardNavigationActive and self.navigationMode == "ui")) and (button.currentColor == button.hoverColor)
    local isKeyboardFocused = (self.uIkeyboardNavigationActive and self.activeUIElement and 
                              self.activeUIElement.name == "toggleButton")
    
    if isMouseHovered or isKeyboardFocused then
        love.graphics.setColor(255/255, 240/255, 220/255, 0.8)
        love.graphics.setLineWidth(2.5)
    else
        local border = self.colors.border
        love.graphics.setColor(border[1], border[2], border[3], border[4] or 1)
        love.graphics.setLineWidth(2)
    end
    love.graphics.rectangle("line", buttonX, y, width, height, 8, 8)
    love.graphics.setLineWidth(1)
    
    -- Inner accent line only when focused/hovered
    if isMouseHovered or isKeyboardFocused then
        local accent = uiTheme.lighten(self.colors.highlight, 0.3)
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.35)
        love.graphics.rectangle("line", buttonX + 3, y + 3, width - 6, height - 6, 6, 6)
    end
    
    -- Button text
    local shadowColor = uiTheme.darken(self.colors.text, 0.6)
    love.graphics.setColor(shadowColor[1], shadowColor[2], shadowColor[3], 0.7)
    love.graphics.printf(button.text, buttonX + 1, y + 16, width, "center")
    
    local textColor = self.colors.text
    love.graphics.setColor(textColor[1], textColor[2], textColor[3], textColor[4] or 0.9)
    love.graphics.printf(button.text, buttonX, y + 15, width, "center")
    
    return button
end


function uiClass:drawReturnToResultsButton()
    local button = self.gameOverPanel.returnButton
    local buttonX = SETTINGS.DISPLAY.WIDTH - 250
    local buttonY = 410
    local panelWidth = self.panelWidth
    local panelHeight = self.panelHeight
    
    -- Draw the panel background first
    self:drawPhaseDetailsBackground(buttonX, buttonY, panelWidth, panelHeight)
    
    -- Calculate button position same way as phase button
    local padding = 15
    local buttonWidth = panelWidth - padding * 2
    local buttonHeight = 40
    
    -- Store button position
    button.x = buttonX + padding
    button.y = buttonY + panelHeight - buttonHeight - padding
    button.width = buttonWidth
    button.height = buttonHeight
    
    -- Ensure consistent colors during keyboard navigation: only focused button uses hover color
    local kbActive = (self.uIkeyboardNavigationActive and self.navigationMode == "ui")
    if kbActive then
        if self.activeUIElement and self.activeUIElement.name == "returnButton" then
            button.currentColor = button.hoverColor
        else
            button.currentColor = button.normalColor or self.colors.button
        end
    else
        -- When not in keyboard mode, normalize color if mouse is not over the button
        local mx, my = love.mouse.getPosition()
        local transformedX = (mx - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
        local transformedY = (my - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
        local isOver = (transformedX >= button.x and transformedX <= button.x + button.width and transformedY >= button.y and transformedY <= button.y + button.height)
        if not isOver then
            button.currentColor = button.normalColor or self.colors.button
        end
    end
    -- Draw using the currentColor
    love.graphics.setColor(button.currentColor)
    love.graphics.rectangle("fill", button.x, button.y, button.width, button.height, 8, 8)
    
    -- Button border - whitish border only when actually hovered or focused
    -- Ignore mouse hover while keyboard navigation is active
    local isKeyboardFocused = kbActive and self.activeUIElement and (self.activeUIElement.name == "returnButton")
    local isMouseHovered = false
    if not kbActive then
        local mx, my = love.mouse.getPosition()
        local transformedX = (mx - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
        local transformedY = (my - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
        isMouseHovered = (transformedX >= button.x and transformedX <= button.x + button.width and transformedY >= button.y and transformedY <= button.y + button.height)
    end
    
    if isMouseHovered or isKeyboardFocused then
        love.graphics.setColor(255/255, 240/255, 220/255, 0.8)
        love.graphics.setLineWidth(2.5)
    else
        local border = self.colors.border
        love.graphics.setColor(border[1], border[2], border[3], border[4] or 1)
        love.graphics.setLineWidth(2)
    end
    love.graphics.rectangle("line", button.x, button.y, button.width, button.height, 8, 8)
    love.graphics.setLineWidth(1)
    
    -- Inner accent line only when hovered or focused
    if isMouseHovered or isKeyboardFocused then
        local accent = uiTheme.lighten(self.colors.highlight, 0.35)
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.3)
        love.graphics.rectangle("line", button.x + 3, button.y + 3, button.width - 6, button.height - 6, 6, 6)
    end
    
    -- Button text with shadow
    local shadowColor = uiTheme.darken(self.colors.text, 0.6)
    love.graphics.setColor(shadowColor[1], shadowColor[2], shadowColor[3], 0.7)
    love.graphics.printf(button.text, button.x + 1, button.y + 11, button.width, "center")
    
    local textColor = self.colors.text
    love.graphics.setColor(textColor[1], textColor[2], textColor[3], textColor[4] or 1)
    love.graphics.printf(button.text, button.x, button.y + 10, button.width, "center")
end

function uiClass:drawPhaseDetailsBackground(x, y, width, height)
    local panelColor = uiTheme.darken(self.colors.background, 0.1)
    love.graphics.setColor(panelColor[1], panelColor[2], panelColor[3], 0.92)
    love.graphics.rectangle("fill", x, y, width, height, 5, 5)
    
    local border = self.colors.border
    love.graphics.setColor(border[1], border[2], border[3], border[4] or 1)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, width, height, 5, 5)
    love.graphics.setLineWidth(1)
    
    local inner = uiTheme.lighten(self.colors.highlight, 0.15)
    love.graphics.setColor(inner[1], inner[2], inner[3], 0.6)
    love.graphics.rectangle("line", x + 3, y + 3, width - 6, height - 6, 3, 3)
    
    local headerColor = uiTheme.darken(self.colors.highlight, 0.05)
    love.graphics.setColor(headerColor[1], headerColor[2], headerColor[3], 0.95)
    love.graphics.rectangle("fill", x + 10, y + 10, width - 20, 30, 4, 4)
    
    local textColor = self.colors.text
    love.graphics.setColor(textColor[1], textColor[2], textColor[3], textColor[4] or 0.95)
    love.graphics.printf("BATTLEFIELD VIEW", x, y + 17, width, "center")
    
    local separatorColor = uiTheme.darken(self.colors.highlight, 0.25)
    love.graphics.setColor(separatorColor[1], separatorColor[2], separatorColor[3], 0.75)
    love.graphics.line(x + 10, y + 45, x + width - 10, y + 45)
    
    local bodyColor = uiTheme.darken(self.colors.text, 0.2)
    love.graphics.setColor(bodyColor[1], bodyColor[2], bodyColor[3], bodyColor[4] or 0.85)
    love.graphics.printf("Return to the results screen to see game statistics and access the main menu.", x + 15, y + 70, width - 30, "center")
end

-- Add these helper functions if they're missing
function uiClass:drawPanelWithGradient(x, y, width, height)
    local baseColor = uiTheme.darken(self.colors.background, 0.08)
    local topColor = uiTheme.lighten(self.colors.background, 0.05)
    local segments = 16
    local segmentHeight = height / segments

    for i = 0, segments - 1 do
        local t = i / (segments - 1)
        local r = baseColor[1] + (topColor[1] - baseColor[1]) * t
        local g = baseColor[2] + (topColor[2] - baseColor[2]) * t
        local b = baseColor[3] + (topColor[3] - baseColor[3]) * t
        local aBase = baseColor[4] or 0.9
        local aTop = topColor[4] or 0.92
        local a = aBase + (aTop - aBase) * t
        love.graphics.setColor(r, g, b, a)
        love.graphics.rectangle("fill", x, y + i * segmentHeight, width, segmentHeight + 1)
    end

    local border = self.colors.border
    love.graphics.setColor(border[1], border[2], border[3], border[4] or 1)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, width, height, 12, 12)
    love.graphics.setLineWidth(1)
end

function uiClass:drawGameOverTitle(x, y)
    local titleY = y + 25
    local width = self.gameOverPanel.width
    local defaultFont = love.graphics.getFont()
    local titleText = "GAME COMPLETE"

    -- Simplified title using theme styling
    love.graphics.setColor(self.colors.text)
    love.graphics.printf(titleText, x, titleY, width, "center")
    
    -- Underline using highlight color
    local textWidth = defaultFont:getWidth(titleText)
    local lineY = titleY + defaultFont:getHeight() + 8
    local highlight = uiTheme.lighten(self.colors.highlight, 0.2)
    love.graphics.setColor(highlight[1], highlight[2], highlight[3], highlight[4] or 0.85)
    love.graphics.rectangle("fill", x + (width - textWidth)/2, lineY, textWidth, 2)
end

function uiClass:drawDecorativeSeparator(x, y, width)
    love.graphics.setLineWidth(2)
    local base = uiTheme.darken(self.colors.highlight, 0.15)
    love.graphics.setColor(base[1], base[2], base[3], 0.6)
    love.graphics.line(x, y, x + width, y)
    love.graphics.setLineWidth(1)
end
--------------------------------------------------
-- UPDATE METHODS
--------------------------------------------------
function uiClass:update(dt)
    -- Update typewriter effect
    self:updateTypewriter(dt)
    
    -- Update turn zoom effect
    self:updateTurnZoom(dt)
    
    -- Update bubble triangle animation
    self:updateBubbleTriangle(dt)
    
    -- Update click animation
    if self.buttonAnimation.active then
        self.buttonAnimation.timer = self.buttonAnimation.timer + dt
        if self.buttonAnimation.timer >= self.buttonAnimation.duration then
            self.buttonAnimation.active = false
        end
    end

    -- Update continuous pulsing animation
    if self.pulsing.active then
        self.pulsing.scale = self.pulsing.scale + (self.pulsing.direction * dt * self.pulsing.speed * 0.08)

        -- Change direction when reaching limits
        if self.pulsing.scale >= self.pulsing.maxScale then
            self.pulsing.direction = -1
        elseif self.pulsing.scale <= self.pulsing.minScale then
            self.pulsing.direction = 1
        end
    end

    if self.onlineReactionNotification.visible then
        local elapsed = self:getNowSeconds() - (self.onlineReactionNotification.startedAt or 0)
        if elapsed >= (self.onlineReactionNotification.duration or ONLINE_REACTION_NOTIFICATION_DURATION) then
            self.onlineReactionNotification.visible = false
        end
    end

    if self.navigationMode == "ui" and self.uIkeyboardNavigationActive then
        self:syncKeyboardAndMouseFocus()
        -- Check if current focus is on phase button that no longer exists
        if self.activeUIElement and 
           self.activeUIElement.name == "phaseButton" and 
           (not self.phaseButton or not self.phaseButton.actionType) then
           
            -- Phase button disappeared, switch focus to grid
            self.navigationMode = "grid"
            self.uIkeyboardNavigationActive = false
            self.forceInfoPanelDefault = false
            
            -- Set grid's keyboard selected cell to position (8,8)
            if self.gameRuler and self.gameRuler.currentGrid and
               self.gameRuler.currentPhase ~= "gameOver" then
                self.gameRuler.currentGrid.keyboardSelectedCell = {row = 8, col = 8}
                
                -- Update the mouse hover cell to match keyboard selection
                local cell = self.gameRuler.currentGrid:getCell(8, 8)
                if cell then
                    -- Clear hover cell first to ensure sound plays on transition
                    self.gameRuler.currentGrid.mouseHoverCell = nil
                    -- FIXED: Use showHoverIndicator instead of updateHoverIndicatorColor
                    self.gameRuler.currentGrid:showHoverIndicator(cell)
                end
                
                self.gameRuler.currentGrid.uiNavigationActive = false
                HOVER_INDICATOR_STATE.IS_HIDDEN = false
            end
            
            -- Re-initialize UI elements list to remove the phase button
            self:initializeUIElements()
        elseif self.activeUIElement and self:isReactionButtonName(self.activeUIElement.name) then
            local reactionButton = self:getOnlineReactionButtonByName(self.activeUIElement.name)
            if not reactionButton then
                self.navigationMode = "grid"
                self.uIkeyboardNavigationActive = false
                self.forceInfoPanelDefault = false
                self.currentUIElementIndex = nil
                self.activeUIElement = nil
                if self.gameRuler and self.gameRuler.currentGrid and self.gameRuler.currentPhase ~= "gameOver" then
                    self.gameRuler.currentGrid.uiNavigationActive = false
                    HOVER_INDICATOR_STATE.IS_HIDDEN = false
                end
                self:initializeUIElements()
            elseif reactionButton.disabledVisual == true then
                self:initializeUIElements()
                for i, element in ipairs(self.uiElements) do
                    if element.name == "surrenderButton" or element.name == "gameLogPanel" then
                        self.currentUIElementIndex = i
                        self.activeUIElement = element
                        self:syncKeyboardAndMouseFocus()
                        break
                    end
                end
            end
        end
    end

    if self.gameRuler and self.gameRuler.currentPhase == "gameOver" then
        if not self.gameOverPanel.animationComplete then
            -- Animate panel sliding in
            if self.gameOverPanel.currentY < self.gameOverPanel.targetY then
                self.gameOverPanel.currentY = self.gameOverPanel.currentY + (800 * dt)
                if self.gameOverPanel.currentY >= self.gameOverPanel.targetY then
                    self.gameOverPanel.currentY = self.gameOverPanel.targetY
                    self.gameOverPanel.animationComplete = true

                    -- Re-initialize UI elements after animation completes to ensure proper focus
                    self:initializeUIElements()

                    if self.gameOverPanel.visible then
                        self:spawnConfettiBurst()
                    end
                end
            end
        end
        self:updateConfetti(dt)
    else
        -- Reset animation state when not in game over
        self.gameOverPanel.currentY = -350
        self.gameOverPanel.animationComplete = false
        self.gameOverPanel.animating = false
        self.gameOverPanel.bouncing = false
        self:resetConfetti()
    end
end

function uiClass:updateGameOverScreen(dt)
    local mouseX, mouseY = love.mouse.getPosition()
    
    -- Update panel animation
    if self.gameOverPanel.visible then
        -- Animate panel sliding in
        if self.gameOverPanel.currentY < self.gameOverPanel.targetY then
            self.gameOverPanel.currentY = math.min(
                self.gameOverPanel.currentY + 1200 * dt,
                self.gameOverPanel.targetY
            )
        end
        
        -- Animate alpha fade in
        if self.gameOverPanel.alpha < 1 then
            self.gameOverPanel.alpha = math.min(self.gameOverPanel.alpha + 2 * dt, 1)
        end

        -- Check main menu button hover
        local btn = self.gameOverPanel.button
        if mouseX >= btn.x and mouseX <= btn.x + btn.width and
           mouseY >= btn.y and mouseY <= btn.y + btn.height then
            btn.currentColor = btn.hoverColor
        else
            btn.currentColor = self.colors.button
        end
    end
    
    if self.returnToResultsButton and self.returnToResultsButton.visible then
        local btn = self.returnToResultsButton
        btn.hover = mouseX >= btn.x and mouseX <= btn.x + btn.width and
                    mouseY >= btn.y and mouseY <= btn.y + btn.height
        
        if btn.hover then
            btn.currentColor = btn.hoverColor
        else
            btn.currentColor = self.colors.button
        end
    end
end

-- Main draw function
function uiClass:draw(gameRuler)

    -- Update supply arrays before drawing
    self:updateSupplyFromGameRuler()

    -- Clear unit positions for fresh drawing
    self.unitPositions = {}

    if not self.hideSupplyPanels then
        -- Draw supply panels
        self:drawSupplyPanel(30, 50, 220, 260, 1, self.playerSupply1)
        self:drawSupplyPanel(SETTINGS.DISPLAY.WIDTH - 250, 50, 220, 260, 2, self.playerSupply2)
    elseif self:isScenarioControlPanelEnabled() then
        self:drawScenarioObjectivePanel()
        self:drawScenarioControlPanel()
    end

    -- Draw the info panel
    self:drawUnitInfoPanel()

    local activeRuler = gameRuler or self.gameRuler
    local battlefieldGameOverView = activeRuler and activeRuler.currentPhase == "gameOver" and
        self.gameOverPanel and self.gameOverPanel.visible == false

    if gameRuler then
        self:drawUnitActionArrows(gameRuler)
        if not self.hideSupplyPanels then
            self:drawSupplyUnitArrows(gameRuler)
        end
    end

    -- Draw phase info
    if not battlefieldGameOverView and gameRuler then
        self:drawPhaseInfo(SETTINGS.DISPLAY.WIDTH - 250, 410, self.panelWidth, self.panelHeight, gameRuler)
    elseif not battlefieldGameOverView and self.gameRuler then
        self:drawPhaseInfo(SETTINGS.DISPLAY.WIDTH - 250, 410, self.panelWidth, self.panelHeight, self.gameRuler)
    end

    -- Draw turn counter panel
    self:drawTurnCounter(gameRuler.currentTurn, gameRuler.currentPlayer)

    -- Draw surrender panel
    if not battlefieldGameOverView then
        self:drawSurrenderPanel()
    end

    -- Draw the new log panel
    self:drawLogPanel(gameRuler)

    if self.gameRuler and self.gameRuler.currentPhase == "gameOver" and not self.suppressGameOverPanel then
        self:drawGameOverPanel()
    end

    self:drawOnlineReactionNotification()
    self:drawKeyboardNavigationHighlight()

end

function uiClass:drawGameOverScreen(winner, stats)
    if not self.gameOverPanel.visible then
        self:drawReturnToResultsButton()
        return true
    end

    love.graphics.setColor(0, 0, 0, 0.8)
    love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)

    -- Draw the panel background with a more tech-styled look
    self:drawTechGameOverPanel()
end

function uiClass:drawTechGameOverPanel()
    local x = (SETTINGS.DISPLAY.WIDTH - self.gameOverPanel.width) / 2
    local y = self.gameOverPanel.currentY
    local width = self.gameOverPanel.width
    local height = self.gameOverPanel.height
    
    -- Panel background
    love.graphics.setColor(0.05, 0.1, 0.2, 0.95)
    love.graphics.rectangle("fill", x, y, width, height, 10, 10)
    
    -- Tech border
    love.graphics.setColor(0.2, 0.6, 1, 0.8)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", x, y, width, height, 10, 10)
    
    -- Tech lines
    love.graphics.setLineWidth(1)
    love.graphics.setColor(0.2, 0.6, 1, 0.4)
    
    -- Horizontal tech lines
    for i = 1, 8 do
        local lineY = y + (height / 9) * i
        love.graphics.line(x + 20, lineY, x + width - 20, lineY)
    end
    
    -- Diagonal corner accents
    love.graphics.setColor(0.2, 0.6, 1, 0.6)
    love.graphics.setLineWidth(2)
    -- Top left
    love.graphics.line(x, y + 30, x + 30, y)
    -- Top right
    love.graphics.line(x + width - 30, y, x + width, y + 30)
    -- Bottom left
    love.graphics.line(x, y + height - 30, x + 30, y + height)
    -- Bottom right
    love.graphics.line(x + width - 30, y + height, x + width, y + height - 30)
    
    -- Reset line width
    love.graphics.setLineWidth(1)
    
    -- Draw "GAME OVER" title with glowing effect
    local titleText = "GAME OVER"
    love.graphics.setFont(self.fonts.huge)
    local textWidth = self.fonts.huge:getWidth(titleText)
    
    -- Shadow/glow effect
    love.graphics.setColor(0.2, 0.6, 1, 0.3)
    love.graphics.print(titleText, x + (width - textWidth) / 2 + 2, y + 32)
    
    -- Main title
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.print(titleText, x + (width - textWidth) / 2, y + 30)
    
    -- Draw winner banner
    self:drawWinnerBanner(self.gameRuler.winner, x, y + 110, width)
    
    -- Draw game statistics
    self:drawGameStats(self.gameRuler.gameStats, x + 40, y + 200, width - 80)
    
    -- Position and draw the buttons
    local buttonY = y + height - 70  -- Adjusted position since we're only showing one button
    
    -- Main menu button
    self.gameOverPanel.button.x = x + (width / 2) - (self.gameOverPanel.button.width / 2)
    self.gameOverPanel.button.y = buttonY
    self:drawButton(self.gameOverPanel.button)
    
    -- Toggle button - positioned above the main button
    self.gameOverPanel.toggleButton.x = x + (width / 2) - (self.gameOverPanel.toggleButton.width / 2)
    self.gameOverPanel.toggleButton.y = buttonY - self.gameOverPanel.toggleButton.height - 20
    self:drawButton(self.gameOverPanel.toggleButton)
end

function uiClass:handleGameOverPanelClicks(x, y)
    if self:isButtonClicked(self.gameOverPanel.button, x, y) then
        -- Play click sound
        self:playButtonBeep()
        -- Existing code for the main menu button
        self.gameRuler:returnToMainMenu()
        return true
    elseif self:isButtonClicked(self.gameOverPanel.toggleButton, x, y) then
        -- Play click sound
        self:playButtonBeep()
        -- Existing code for toggle button
        self.gameOverPanel.visible = false
        self.gameOverPanel.showResults = true
        self.gameOverPanel.particles = {}
        return true
    end
    
    return false
end

-- Initialize UI elements for keyboard navigation
function uiClass:initializeUIElements()
    self.uiElements = {}
    -- Reset keyboard focus tracking when initializing UI elements
    self.lastKeyboardFocusedButton = nil
    
    -- Add phase button if available
    if self.phaseButton then
        table.insert(self.uiElements, {
            type = "button",
            name = "phaseButton",
            x = self.phaseButton.x,
            y = self.phaseButton.y,
            width = self.phaseButton.width,
            height = self.phaseButton.height,
            action = function()
                if not self.phaseButton then
                    return false
                end
                return self:handlePhaseButtonClick(
                    self.phaseButton.x + self.phaseButton.width / 2,
                    self.phaseButton.y + self.phaseButton.height / 2
                )
            end
        })
    end

    if self:updateScenarioControlLayout()
        and (not self.gameRuler or self.gameRuler.currentPhase ~= "gameOver") then
        table.insert(self.uiElements, {
            type = "button",
            name = "scenarioBackButton",
            x = self.scenarioBackButton.x,
            y = self.scenarioBackButton.y,
            width = self.scenarioBackButton.width,
            height = self.scenarioBackButton.height,
            action = function()
                return self:triggerScenarioBackAction()
            end
        })
        table.insert(self.uiElements, {
            type = "button",
            name = "scenarioRetryButton",
            x = self.scenarioRetryButton.x,
            y = self.scenarioRetryButton.y,
            width = self.scenarioRetryButton.width,
            height = self.scenarioRetryButton.height,
            action = function()
                return self:triggerScenarioRetryAction()
            end
        })
    end

    for _, button in ipairs(self:getOnlineReactionButtons()) do
        table.insert(self.uiElements, {
            type = "button",
            name = button.name,
            x = button.x,
            y = button.y,
            width = button.width,
            height = button.height,
            disabled = button.disabledVisual == true,
            action = function()
                return self:handleOnlineReactionButtonClick(button.x + button.width / 2, button.y + button.height / 2)
            end
        })
    end

    if self.unitCodexButton and self.onUnitCodexRequested and self.gameRuler and self.gameRuler.currentPhase ~= "gameOver" then
        table.insert(self.uiElements, {
            type = "button",
            name = "unitCodexButton",
            x = self.unitCodexButton.x,
            y = self.unitCodexButton.y,
            width = self.unitCodexButton.width,
            height = self.unitCodexButton.height,
            action = function() return self.onUnitCodexRequested() end
        })
    end

    -- Add game log panel if available
    local allowGameLogPanel = not (self.gameRuler and self.gameRuler.currentPhase == "gameOver" and self.gameOverPanel and self.gameOverPanel.visible)
    if self.gameLogPanel and allowGameLogPanel then
        table.insert(self.uiElements, {
            type = "panel",
            name = "gameLogPanel",
            x = self.gameLogPanel.x,
            y = self.gameLogPanel.y,
            width = self.gameLogPanel.width,
            height = self.gameLogPanel.height,
            action = function() self:handleGameLogPanelClick(self.gameLogPanel.x + self.gameLogPanel.width/2, self.gameLogPanel.y + self.gameLogPanel.height/2) end
        })
    end

    if self.gameRuler and self.gameRuler.currentPhase == "turn" and self.gameRuler.currentTurnPhase == "actions" and
        (GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL or GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET or
        self.gameRuler.currentPlayer ~= GAME.CURRENT.AI_PLAYER_NUMBER) and self.surrenderButton then

        table.insert(self.uiElements, {
            type = "button",
            name = "surrenderButton",
            x = self.surrenderButton.x,
            y = self.surrenderButton.y,
            width = self.surrenderButton.width,
            height = self.surrenderButton.height,
            action = function()
                -- Show confirmation dialog
                local surrenderText
                if self.gameRuler and self.gameRuler.currentPlayer == 1 then
                    surrenderText = "MOO OVER MEOW!\n\nAre you sure you want to concede?"
                else
                    surrenderText = "MEOW OVER MOO!\n\nAre you sure you want to concede?"
                end
                ConfirmDialog.show(
                    surrenderText,
                    function()
                        -- Confirmed surrender
                        self:surrenderGame()
                    end,
                    function()
                        -- Cancel action
                    end
                )
                return true
            end
        })
    end

    if not (self.gameRuler and self.gameRuler.currentPhase == "gameOver") then
        for i, unitPos in ipairs(self.unitPositions) do
            table.insert(self.uiElements, {
                type = "supplyUnit",
                name = unitPos.isEmpty and "emptySupplyCell_" .. i or "supplyUnit_" .. i,
                x = unitPos.x,
                y = unitPos.y,
                width = unitPos.size,
                height = unitPos.size,
                unitData = unitPos,
                action = function() self:handleClickOnSupplyPanel(unitPos.x + unitPos.size/2, unitPos.y + unitPos.size/2) end
            })
        end
    end

    -- Add game over buttons if in game over state
    if self.gameRuler and self.gameRuler.currentPhase == "gameOver" then
        self.navigationMode = "ui"
        self.uIkeyboardNavigationActive = true

        if self.gameOverPanel.visible then
            -- Main menu button
            if self.gameOverPanel.button then
                table.insert(self.uiElements, {
                    type = "button",
                    name = "mainMenuButton",
                    x = self.gameOverPanel.button.x,
                    y = self.gameOverPanel.button.y,
                    width = self.gameOverPanel.button.width,
                    height = self.gameOverPanel.button.height,
                    action = function() 
                        ConfirmDialog.show(
                            "Return to main menu?",
                            function()
                                if self.stateMachineRef then
                                    self.stateMachineRef.changeState("mainMenu")
                                elseif self.gameRuler and self.gameRuler.returnToMainMenu then
                                    self.gameRuler:returnToMainMenu()
                                end
                            end,
                            function() end
                        )
                        return true
                    end
                })
            end

            -- Toggle button 
            if self.gameOverPanel.toggleButton then
                table.insert(self.uiElements, {
                    type = "button",
                    name = "toggleButton",
                    x = self.gameOverPanel.toggleButton.x,
                    y = self.gameOverPanel.toggleButton.y,
                    width = self.gameOverPanel.toggleButton.width,
                    height = self.gameOverPanel.toggleButton.height,
                    action = function()
                        self.gameOverPanel.visible = false
                        self:drawReturnToResultsButton()
                        self:initializeUIElements()
                        for i, element in ipairs(self.uiElements) do
                            if element.name == "returnButton" then
                                element.x = self.gameOverPanel.returnButton.x
                                element.y = self.gameOverPanel.returnButton.y
                                element.width = self.gameOverPanel.returnButton.width
                                element.height = self.gameOverPanel.returnButton.height
                                self.currentUIElementIndex = i
                                self.activeUIElement = element
                                HOVER_INDICATOR_STATE.IS_HIDDEN = true
                                self:syncKeyboardAndMouseFocus()
                                break
                            end
                        end
                        return true
                    end
                })
            end
            
            -- Set initial focus to main menu button when panel is visible
            for i, element in ipairs(self.uiElements) do
                if element.name == "mainMenuButton" then
                    self.currentUIElementIndex = i
                    self.activeUIElement = element
                    self:syncKeyboardAndMouseFocus()
                    break
                end
            end
        else
            -- Return button (when battlefield is visible)
            if self.gameOverPanel.returnButton then
                table.insert(self.uiElements, {
                    type = "button",
                    name = "returnButton",
                    x = self.gameOverPanel.returnButton.x,
                    y = self.gameOverPanel.returnButton.y,
                    width = self.gameOverPanel.returnButton.width,
                    height = self.gameOverPanel.returnButton.height,
                    action = function()
                        self.gameOverPanel.visible = true
                        self:drawReturnToResultsButton()
                        self:initializeUIElements()
                        for i, element in ipairs(self.uiElements) do
                            if element.name == "toggleButton" then
                                self.currentUIElementIndex = i
                                self.activeUIElement = element
                                break
                            end
                        end
                        return true
                    end
                })
                
                -- Set initial focus to return button when battlefield is visible
                for i, element in ipairs(self.uiElements) do
                    if element.name == "returnButton" then
                        self.currentUIElementIndex = i
                        self.activeUIElement = element
                        self:syncKeyboardAndMouseFocus()
                        break
                    end
                end
            end
        end
    end

    if #self.uiElements > 0 then
        if not self.currentUIElementIndex or not self.activeUIElement then
            local initialIndex = 1
            for i, element in ipairs(self.uiElements) do
                if element.disabled ~= true then
                    initialIndex = i
                    break
                end
            end
            self.currentUIElementIndex = initialIndex
            self.activeUIElement = self.uiElements[self.currentUIElementIndex]
            if self.activeUIElement.type == "supplyUnit" and self.activeUIElement.unitData then
                local index = self.activeUIElement.unitData.index
                local panelPlayer = self.activeUIElement.unitData.panelPlayer
                local row = math.floor((index - 1) / 4) + 1
                local col = ((index - 1) % 4) + 1
                self.currentNavRow = row
                self.currentNavCol = col
                self.currentNavPanel = panelPlayer
            end
        end
    else
        self.currentUIElementIndex = nil
        self.activeUIElement = nil
    end
end

-- Keyboard navigation between UI elements
function uiClass:navigateUI(key)
    -- print("DEBUG: navigateUI called with key:", key, "activeUIElement:", self.activeUIElement and self.activeUIElement.name or "nil")
    
    if self.selectedUnit and self.selectedUnitPlayer and self.selectedSource == "supply" and not self.keyboardNavInitiated and
       (key == "up" or key == "down" or key == "left" or key == "right" or key == "w" or key == "s" or key == "a" or key == "d") then

        -- Set flag to indicate keyboard navigation has been initiated
        self.keyboardNavInitiated = true

        -- Switch to grid navigation at position (1,1)
        self:clearHoveredInfo()
        self.navigationMode = "grid"
        self.uIkeyboardNavigationActive = false
        self.forceInfoPanelDefault = false

        self:resetButtonHighlights()

        if self.gameRuler and self.gameRuler.currentGrid then
            self.gameRuler.currentGrid.keyboardSelectedCell = {row = 1, col = 1}
            local cell = self.gameRuler.currentGrid:getCell(1, 1)
            if cell then
                -- Clear hover cell first to ensure sound plays on transition
                self.gameRuler.currentGrid.mouseHoverCell = nil
                self.gameRuler.currentGrid:showHoverIndicator(cell)
            end

            self.gameRuler.currentGrid.uiNavigationActive = false
            HOVER_INDICATOR_STATE.IS_HIDDEN = false
        end

        return true
    end

    if self.gameRuler and self.gameRuler.currentPhase == "gameOver" then
        if key == "up" or key == "down" or key == "left" or key == "right" or key == "w" or key == "s" or key == "a" or key == "d" then
            -- Restore keyboard navigation if mouse was controlling
            if not self.uIkeyboardNavigationActive then
                self.uIkeyboardNavigationActive = true
                self.navigationMode = "ui"
                self.lastKeyboardFocusedButton = nil
                self.lastKeyboardFocusedPanel = nil
                self.lastSupplyKey = nil
            end
            
            -- Get the indexes of our game over buttons/panels
            local mainMenuButtonIndex = nil
            local toggleButtonIndex = nil
            local returnButtonIndex = nil
            local gameLogPanelIndex = nil

            for i, elem in ipairs(self.uiElements) do
                if elem.name == "mainMenuButton" then mainMenuButtonIndex = i end
                if elem.name == "toggleButton" then toggleButtonIndex = i end
                if elem.name == "returnButton" then returnButtonIndex = i end
                if elem.name == "gameLogPanel" then gameLogPanelIndex = i end
            end

            -- Handle navigation between buttons
            if self.gameOverPanel.visible then
                -- Visible panel - navigate between main menu and toggle button
                
                if not mainMenuButtonIndex or not toggleButtonIndex then
                    -- Buttons not found, can't navigate
                    return false
                end
                
                if not self.currentUIElementIndex or 
                   (self.currentUIElementIndex ~= mainMenuButtonIndex and self.currentUIElementIndex ~= toggleButtonIndex) then
                    -- If not on any button, select the main menu button as default
                    self.currentUIElementIndex = mainMenuButtonIndex
                    self.activeUIElement = self.uiElements[mainMenuButtonIndex]
                    self:syncKeyboardAndMouseFocus()
                    return true
                elseif self.currentUIElementIndex == mainMenuButtonIndex then
                    -- From main menu button, any direction goes to toggle button
                    self.currentUIElementIndex = toggleButtonIndex
                    self.activeUIElement = self.uiElements[toggleButtonIndex]
                    self:syncKeyboardAndMouseFocus()
                    return true
                elseif self.currentUIElementIndex == toggleButtonIndex then
                    -- From toggle button, any direction goes to main menu button
                    self.currentUIElementIndex = mainMenuButtonIndex
                    self.activeUIElement = self.uiElements[mainMenuButtonIndex]
                    self:syncKeyboardAndMouseFocus()
                    return true
                end
            else
                -- Battlefield view - navigate between Return button and Game Log panel
                -- Ensure at least one of them exists
                if (not returnButtonIndex or not gameLogPanelIndex) and not self.gameOverPanel.visible then
                    if self.gameLogPanel then
                        self:initializeUIElements()
                        mainMenuButtonIndex, toggleButtonIndex, returnButtonIndex, gameLogPanelIndex = nil, nil, nil, nil
                        for i, elem in ipairs(self.uiElements) do
                            if elem.name == "mainMenuButton" then mainMenuButtonIndex = i end
                            if elem.name == "toggleButton" then toggleButtonIndex = i end
                            if elem.name == "returnButton" then returnButtonIndex = i end
                            if elem.name == "gameLogPanel" then gameLogPanelIndex = i end
                        end
                    end
                end

                if not returnButtonIndex and not gameLogPanelIndex then
                    return false
                end

                -- If nothing focused or focused on something else, default to Return, else stay
                if not self.currentUIElementIndex or 
                   (self.currentUIElementIndex ~= returnButtonIndex and self.currentUIElementIndex ~= gameLogPanelIndex) then
                    local targetIndex = returnButtonIndex or gameLogPanelIndex
                    self.currentUIElementIndex = targetIndex
                    self.activeUIElement = self.uiElements[targetIndex]
                    self:syncKeyboardAndMouseFocus()
                    return true
                end

                -- Specific transitions requested:
                -- Left from Return -> Game Log
                if (key == "left" or key == "a") and self.currentUIElementIndex == returnButtonIndex and gameLogPanelIndex then
                    self.currentUIElementIndex = gameLogPanelIndex
                    self.activeUIElement = self.uiElements[gameLogPanelIndex]
                    self:syncKeyboardAndMouseFocus()
                    return true
                end
                -- Right from Game Log -> Return
                if (key == "right" or key == "d") and self.currentUIElementIndex == gameLogPanelIndex and returnButtonIndex then
                    self.currentUIElementIndex = returnButtonIndex
                    self.activeUIElement = self.uiElements[returnButtonIndex]
                    self:syncKeyboardAndMouseFocus()
                    return true
                end

                -- Other directions: keep current focus
                return true
            end
        elseif key == "return" or key == "space" then
            -- If focusing game log panel, trigger its action and ensure viewer opens
            if self.activeUIElement and self.activeUIElement.name == "gameLogPanel" then
                if self.activeUIElement.action then
                    local handled = self.activeUIElement.action()
                    if handled == true then return true end
                end
                if self.gameRuler and GameLogViewer and GameLogViewer.show then
                    GameLogViewer.show(self.gameRuler)
                end
                return true
            end

            -- Execute element action normally
            if self.activeUIElement and self.activeUIElement.action then
                local result = self.activeUIElement.action()
                if result == true then
                    return true
                end
            end
            return true
        end

        -- Always block further processing in game over mode
        return true
    end

    -- If there are no UI elements, we can't navigate
    if #self.uiElements == 0 then
        return false
    end

    -- Handle keyboard navigation between UI elements
    if key == "up" or key == "down" or key == "left" or key == "right" or key == "w" or key == "s" or key == "a" or key == "d" then
        local currentElement = self.uiElements[self.currentUIElementIndex]
        if not currentElement then return false end

        -- Scenario panel controls: keyboard navigation between panel buttons and grid.
        if currentElement.name == "scenarioBackButton" or currentElement.name == "scenarioRetryButton" then
            local function focusScenarioButton(buttonName)
                for i, element in ipairs(self.uiElements) do
                    if element.name == buttonName then
                        self:resetButtonHighlights()
                        self.currentUIElementIndex = i
                        self.activeUIElement = self.uiElements[i]
                        self:syncKeyboardAndMouseFocus()
                        return true
                    end
                end
                return false
            end

            local function switchToGridFromScenarioPanel()
                self:resetButtonHighlights()
                self:clearHoveredInfo()
                self.navigationMode = "grid"
                self.uIkeyboardNavigationActive = false
                self.forceInfoPanelDefault = false
                self.currentUIElementIndex = nil
                self.activeUIElement = nil
                self:clearGameLogPanelHover()

                if self.gameRuler and self.gameRuler.currentGrid then
                    self.gameRuler.currentGrid.keyboardSelectedCell = { row = 4, col = 8 }
                    local cell = self.gameRuler.currentGrid:getCell(4, 8)
                    if cell then
                        self.gameRuler.currentGrid.mouseHoverCell = nil
                        self.gameRuler.currentGrid:showHoverIndicator(cell)
                    end
                    self.gameRuler.currentGrid.uiNavigationActive = false
                    HOVER_INDICATOR_STATE.IS_HIDDEN = false
                end
                return true
            end

            if key == "right" or key == "d" then
                if currentElement.name == "scenarioBackButton" then
                    return focusScenarioButton("scenarioRetryButton")
                end
                return false
            elseif key == "left" or key == "a" then
                if currentElement.name == "scenarioRetryButton" then
                    return focusScenarioButton("scenarioBackButton")
                end
                return switchToGridFromScenarioPanel()
            elseif key == "up" or key == "w" or key == "down" or key == "s" then
                if currentElement.name == "scenarioBackButton" then
                    return focusScenarioButton("scenarioRetryButton")
                end
                return focusScenarioButton("scenarioBackButton")
            end
            return false
        -- Special handling for phase button (non-grid element)
        elseif currentElement.name == "phaseButton" then
            if key == "up" or key == "w" then
                -- RESET HIGHLIGHTS FIRST
                self:resetButtonHighlights()

                -- First check if the surrender button is available
                local surrenderButtonIndex = nil

                for i, element in ipairs(self.uiElements) do
                    if element.type == "button" and element.name == "surrenderButton" then
                        surrenderButtonIndex = i
                        break
                    end
                end

                -- If surrender button is found, try to navigate to it first
                if surrenderButtonIndex and self.surrenderButton and 
                   self.gameRuler and self.gameRuler.currentPhase == "turn" and 
                   self.gameRuler.currentTurnPhase == "actions" and
                   (GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL or GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET or
                    self.gameRuler.currentPlayer ~= GAME.CURRENT.AI_PLAYER_NUMBER) then

                    self.currentUIElementIndex = surrenderButtonIndex
                    self.activeUIElement = self.uiElements[surrenderButtonIndex]
                    self:syncKeyboardAndMouseFocus()
                    return true
                end

                -- If no surrender button or it's not active, go to supply panel 2, row 4, col 2 (emptySupplyCell_32)
                local targetPanel = 2
                local targetRow = 4
                local targetCol = 2

                self:resetButtonHighlights()

                -- Find the element at this position
                local newElement = self:findUIElementByPosition(targetPanel, targetRow, targetCol)
                if newElement then
                    self.currentUIElementIndex = newElement
                    self.activeUIElement = self.uiElements[self.currentUIElementIndex]

                    -- Update persistent navigation state
                    self.currentNavPanel = targetPanel
                    self.currentNavRow = targetRow
                    self.currentNavCol = targetCol

                    self:syncKeyboardAndMouseFocus()
                    return true
                else
                    -- If findUIElementByPosition fails, try to find emptySupplyCell_32 directly
                    for i, element in ipairs(self.uiElements) do
                        if element.name == "emptySupplyCell_32" then
                            self.currentUIElementIndex = i
                            self.activeUIElement = self.uiElements[i]
                            
                            -- Update persistent navigation state
                            self.currentNavPanel = targetPanel
                            self.currentNavRow = targetRow
                            self.currentNavCol = targetCol
                            
                            self:syncKeyboardAndMouseFocus()
                            return true
                        end
                    end
                end
                
                -- If we reach here, navigation failed, so return false
                return false
            elseif key == "right" or key == "d" then
                -- Right from phase button: stay on phase button (no navigation)
                return false
            elseif key == "left" or key == "a" then
                -- When pressing left from phase button, go to grid position (8,8)
                self.navigationMode = "grid"
                self.uIkeyboardNavigationActive = false
                self.forceInfoPanelDefault = false

                -- Clear active UI element when switching to grid navigation
                self.currentUIElementIndex = nil
                self.activeUIElement = nil

                -- Clear game log panel hover AFTER clearing activeUIElement
                self:clearGameLogPanelHover()
                
                self:resetButtonHighlights()

                if self.gameRuler and self.gameRuler.currentGrid then
                    -- Set grid's keyboard selected cell to position (8,8)
                    self.gameRuler.currentGrid.keyboardSelectedCell = {row = 8, col = 8}
                    local cell = self.gameRuler.currentGrid:getCell(8, 8)
                    if cell then
                        -- Clear hover cell first to ensure sound plays on transition
                        self.gameRuler.currentGrid.mouseHoverCell = nil
                        self.gameRuler.currentGrid:showHoverIndicator(cell)
                    end

                    self.gameRuler.currentGrid.uiNavigationActive = false
                    HOVER_INDICATOR_STATE.IS_HIDDEN = false
                end
                return true
            end
            -- No handling for down from phase button
            return false
        elseif currentElement.name == "gameLogPanel" then
            if key == "right" or key == "d" then
                -- Navigate to grid position (5,1) when pressing right from game log panel
                self:resetButtonHighlights()
                self:clearHoveredInfo()
                self.navigationMode = "grid"
                self.uIkeyboardNavigationActive = false
                self.forceInfoPanelDefault = false
                
                -- Clear active UI element when switching to grid navigation
                self.currentUIElementIndex = nil
                self.activeUIElement = nil
                
                -- Clear game log panel hover AFTER clearing activeUIElement
                self:clearGameLogPanelHover()

                if self.gameRuler and self.gameRuler.currentGrid then
                    -- Set grid's keyboard selected cell to position (5,1)
                    self.gameRuler.currentGrid.keyboardSelectedCell = {row = 5, col = 1}
                    local cell = self.gameRuler.currentGrid:getCell(5, 1)
                    if cell then
                        -- Clear mouseHoverCell before showing hover indicator to ensure sound plays
                        self.gameRuler.currentGrid.mouseHoverCell = nil
                        self.gameRuler.currentGrid:showHoverIndicator(cell)
                    end
                    
                    self.gameRuler.currentGrid.uiNavigationActive = false
                    HOVER_INDICATOR_STATE.IS_HIDDEN = false
                end
                return true
            elseif key == "up" or key == "w" then
                for i, element in ipairs(self.uiElements) do
                    if element.name == "unitCodexButton" then
                        self.currentUIElementIndex = i
                        self.activeUIElement = self.uiElements[i]
                        self:resetButtonHighlights()
                        self:syncKeyboardAndMouseFocus()
                        return true
                    end
                end
                local targetPanel = 1
                local targetRow = 4
                local targetCol = 1
                local newElement = self:findUIElementByPosition(targetPanel, targetRow, targetCol)
                if newElement then
                    self.currentUIElementIndex = newElement
                    self.activeUIElement = self.uiElements[self.currentUIElementIndex]
                    self.currentNavPanel = targetPanel
                    self.currentNavRow = targetRow
                    self.currentNavCol = targetCol
                    self:resetButtonHighlights()
                    self:syncKeyboardAndMouseFocus()
                    return true
                end
            elseif key == "left" or key == "a" or key == "down" or key == "s" then
                return false
            end
            return false
        elseif currentElement.name == "unitCodexButton" then
            if key == "right" or key == "d" then
                self:resetButtonHighlights()
                self:clearHoveredInfo()
                self.navigationMode = "grid"
                self.uIkeyboardNavigationActive = false
                self.forceInfoPanelDefault = false
                self.currentUIElementIndex = nil
                self.activeUIElement = nil
                self:clearGameLogPanelHover()
                if self.gameRuler and self.gameRuler.currentGrid then
                    self.gameRuler.currentGrid.keyboardSelectedCell = {row = 5, col = 1}
                    local cell = self.gameRuler.currentGrid:getCell(5, 1)
                    if cell then
                        self.gameRuler.currentGrid.mouseHoverCell = nil
                        self.gameRuler.currentGrid:showHoverIndicator(cell)
                    end
                    self.gameRuler.currentGrid.uiNavigationActive = false
                    HOVER_INDICATOR_STATE.IS_HIDDEN = false
                end
                return true
            elseif key == "down" or key == "s" then
                for i, element in ipairs(self.uiElements) do
                    if element.name == "gameLogPanel" then
                        self.currentUIElementIndex = i
                        self.activeUIElement = self.uiElements[i]
                        self:resetButtonHighlights()
                        self:syncKeyboardAndMouseFocus()
                        return true
                    end
                end
                return false
            elseif key == "up" or key == "w" then
                local targetPanel = 1
                local targetRow = 4
                local targetCol = 1
                local newElement = self:findUIElementByPosition(targetPanel, targetRow, targetCol)
                if newElement then
                    self.currentUIElementIndex = newElement
                    self.activeUIElement = self.uiElements[self.currentUIElementIndex]
                    self.currentNavPanel = targetPanel
                    self.currentNavRow = targetRow
                    self.currentNavCol = targetCol
                    self:resetButtonHighlights()
                    self:syncKeyboardAndMouseFocus()
                    return true
                end
            elseif key == "left" or key == "a" then
                return false
            end
            return false
        elseif currentElement.name == "surrenderButton" then
            if key == "up" or key == "w" then
                self:resetButtonHighlights()

                -- Navigate to supply panel 2, row 4, col 2
                local targetPanel = 2
                local targetRow = 4
                local targetCol = 2

                -- Find the element at this position
                local newElement = self:findUIElementByPosition(targetPanel, targetRow, targetCol)
                if newElement then
                    self.currentUIElementIndex = newElement
                    self.activeUIElement = self.uiElements[self.currentUIElementIndex]

                    -- Update persistent navigation state
                    self.currentNavPanel = targetPanel
                    self.currentNavRow = targetRow
                    self.currentNavCol = targetCol

                    self:syncKeyboardAndMouseFocus()
                    return true
                end
            elseif key == "down" or key == "s" then
                self:resetButtonHighlights()

                for i, element in ipairs(self.uiElements) do
                    if element.type == "button" and self:isReactionButtonName(element.name) and element.disabled ~= true then
                        self.currentUIElementIndex = i
                        self.activeUIElement = self.uiElements[i]
                        self:syncKeyboardAndMouseFocus()
                        return true
                    end
                end

                -- Navigate to phase button
                for i, element in ipairs(self.uiElements) do
                    if element.type == "button" and element.name == "phaseButton" then
                        self.currentUIElementIndex = i
                        self.activeUIElement = self.uiElements[i]
                        self:syncKeyboardAndMouseFocus()
                        return true
                    end
                end
            elseif key == "left" or key == "a" then
                -- Navigate to grid at position (4,8)
                self:resetButtonHighlights()
                self:clearHoveredInfo()
                self.navigationMode = "grid"
                self.uIkeyboardNavigationActive = false
                self.forceInfoPanelDefault = false
                
                -- Clear active UI element when switching to grid navigation
                self.currentUIElementIndex = nil
                self.activeUIElement = nil
                
                -- Clear game log panel hover AFTER clearing activeUIElement
                self:clearGameLogPanelHover()

                if self.gameRuler and self.gameRuler.currentGrid then
                    -- Set grid's keyboard selected cell to position (4,8)
                    self.gameRuler.currentGrid.keyboardSelectedCell = {row = 4, col = 8}
                    local cell = self.gameRuler.currentGrid:getCell(4, 8)
                    if cell then
                        -- Clear mouseHoverCell before showing hover indicator to ensure sound plays
                        self.gameRuler.currentGrid.mouseHoverCell = nil
                        self.gameRuler.currentGrid:showHoverIndicator(cell)
                    end

                    self.gameRuler.currentGrid.uiNavigationActive = false
                    HOVER_INDICATOR_STATE.IS_HIDDEN = false
                end
                return true
            elseif key == "right" or key == "d" then
                -- Right from surrender button: stay on surrender button (no navigation)
                return false
            end
        elseif self:isReactionButtonName(currentElement.name) then
            local reactionIndices = {}
            for i, element in ipairs(self.uiElements) do
                if element.type == "button" and self:isReactionButtonName(element.name) and element.disabled ~= true then
                    reactionIndices[#reactionIndices + 1] = i
                end
            end

            table.sort(reactionIndices)

            local currentReactionPosition = nil
            for idx, elementIndex in ipairs(reactionIndices) do
                if elementIndex == self.currentUIElementIndex then
                    currentReactionPosition = idx
                    break
                end
            end

            if key == "left" or key == "a" then
                if currentReactionPosition and currentReactionPosition > 1 then
                    self.currentUIElementIndex = reactionIndices[currentReactionPosition - 1]
                    self.activeUIElement = self.uiElements[self.currentUIElementIndex]
                    self:syncKeyboardAndMouseFocus()
                    return true
                end

                self:resetButtonHighlights()
                self:clearHoveredInfo()
                self.navigationMode = "grid"
                self.uIkeyboardNavigationActive = false
                self.forceInfoPanelDefault = false
                self.currentUIElementIndex = nil
                self.activeUIElement = nil
                self:clearGameLogPanelHover()

                if self.gameRuler and self.gameRuler.currentGrid then
                    self.gameRuler.currentGrid.keyboardSelectedCell = {row = 8, col = 8}
                    local cell = self.gameRuler.currentGrid:getCell(8, 8)
                    if cell then
                        self.gameRuler.currentGrid.mouseHoverCell = nil
                        self.gameRuler.currentGrid:showHoverIndicator(cell)
                    end
                    self.gameRuler.currentGrid.uiNavigationActive = false
                    HOVER_INDICATOR_STATE.IS_HIDDEN = false
                end
                return true
            elseif key == "right" or key == "d" then
                if currentReactionPosition and currentReactionPosition < #reactionIndices then
                    self.currentUIElementIndex = reactionIndices[currentReactionPosition + 1]
                    self.activeUIElement = self.uiElements[self.currentUIElementIndex]
                    self:syncKeyboardAndMouseFocus()
                    return true
                end
                return false
            elseif key == "up" or key == "w" then
                for i, element in ipairs(self.uiElements) do
                    if element.type == "button" and element.name == "surrenderButton" then
                        self.currentUIElementIndex = i
                        self.activeUIElement = self.uiElements[i]
                        self:syncKeyboardAndMouseFocus()
                        return true
                    end
                end
                return false
            elseif key == "down" or key == "s" then
                return false
            end
        end

        -- For supply unit navigation, get the current position
        local currentRow = self.currentNavRow
        local currentCol = self.currentNavCol
        local currentPanel = self.currentNavPanel

        -- Initialize position from element if needed
        if not currentRow or not currentCol or not currentPanel then
            if currentElement.unitData and currentElement.unitData.index then
                local idx = currentElement.unitData.index
                currentRow = math.floor((idx-1)/4) + 1
                currentCol = ((idx-1) % 4) + 1
                currentPanel = currentElement.unitData.panelPlayer

                -- Save to persistent state
                self.currentNavRow = currentRow
                self.currentNavCol = currentCol
                self.currentNavPanel = currentPanel
            else
                -- Default to first panel, first cell if we can't determine position
                currentRow = 1
                currentCol = 1
                currentPanel = 1
                self.currentNavRow = currentRow
                self.currentNavCol = currentCol
                self.currentNavPanel = currentPanel
            end
        end

        -- Calculate new position based on direction
        local newRow = currentRow
        local newCol = currentCol
        local newPanel = currentPanel
        local goToGrid = false
        local gridRow, gridCol = 1, 1

        if key == "up" or key == "w" then
            newRow = currentRow - 1
            if newRow < 1 then newRow = 1 end

        elseif key == "down" or key == "s" then
            newRow = currentRow + 1
            -- Special case: from panel 1, row 4 to codex button, then game log panel
            if currentRow == 4 and newRow > 4 and currentPanel == 1 then
                for i, element in ipairs(self.uiElements) do
                    if element.name == "unitCodexButton" then
                        self.currentUIElementIndex = i
                        self.activeUIElement = self.uiElements[i]
                        self:syncKeyboardAndMouseFocus()
                        return true
                    end
                end
                for i, element in ipairs(self.uiElements) do
                    if element.name == "gameLogPanel" then
                        self.currentUIElementIndex = i
                        self.activeUIElement = self.uiElements[i]
                        self:syncKeyboardAndMouseFocus()
                        return true
                    end
                end
            end
            -- Special case: from panel 2, row 4 to phase button
            if currentRow == 4 and newRow > 4 and currentPanel == 2 then
                -- First check if the surrender button is available
                local surrenderButtonIndex = nil

                for i, element in ipairs(self.uiElements) do
                    if element.type == "button" and element.name == "surrenderButton" then
                        surrenderButtonIndex = i
                        break
                    end
                end

                -- If surrender button is found, navigate to it first
                if surrenderButtonIndex and self.surrenderButton and 
                    self.gameRuler and self.gameRuler.currentPhase == "turn" and self.gameRuler.currentTurnPhase == "actions" and
                    (GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL or GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET or self.gameRuler.currentPlayer ~= GAME.CURRENT.AI_PLAYER_NUMBER) then

                    self.currentUIElementIndex = surrenderButtonIndex
                    self.activeUIElement = self.uiElements[surrenderButtonIndex]
                    self:syncKeyboardAndMouseFocus()
                    return true
                end

                for i, element in ipairs(self.uiElements) do
                    if element.type == "button" and self:isReactionButtonName(element.name) and element.disabled ~= true then
                        self.currentUIElementIndex = i
                        self.activeUIElement = self.uiElements[i]
                        self:syncKeyboardAndMouseFocus()
                        return true
                    end
                end

                -- If no surrender button or it's not active, try to find phase button
                for i, element in ipairs(self.uiElements) do
                    if element.type == "button" and element.name == "phaseButton" then
                        self.currentUIElementIndex = i
                        self.activeUIElement = self.uiElements[i]
                        self:syncKeyboardAndMouseFocus()
                        return true
                    end
                end
            end
            if newRow > 4 then newRow = 4 end

        elseif key == "left" or key == "a" then
            newCol = currentCol - 1
            -- If at leftmost column of panel 2, go to grid
            if currentCol == 1 and newCol < 1 and currentPanel == 2 then
                goToGrid = true
                -- Map grid position based on current row
                gridCol = GAME.CONSTANTS.GRID_SIZE  -- Right side of grid
                if currentRow == 1 then
                    gridRow = 1
                elseif currentRow == 2 or currentRow == 3 then
                    gridRow = 2
                else
                    gridRow = 3
                end
            end
            if newCol < 1 then newCol = 1 end

        elseif key == "right" or key == "d" then
            newCol = currentCol + 1
            -- If at rightmost column of panel 1, go to grid
            if currentCol == 4 and newCol > 4 and currentPanel == 1 then
                goToGrid = true
                -- Map grid position based on current row
                gridCol = 1  -- Left side of grid
                if currentRow == 1 then
                    gridRow = 1
                elseif currentRow == 2 or currentRow == 3 then
                    gridRow = 2
                else
                    gridRow = 3
                end
            end
            if newCol > 4 then newCol = 4 end
        end

        -- Handle switching to grid if needed
        if goToGrid then
            self:clearHoveredInfo()
            self.navigationMode = "grid"
            self.uIkeyboardNavigationActive = false
            self.forceInfoPanelDefault = false

            -- Clear sound tracking to ensure sound plays on first grid highlight
            self.lastSupplyKey = nil
            self.lastMouseSupplyKey = nil

            self:resetButtonHighlights()

            if self.gameRuler and self.gameRuler.currentGrid then
                self.gameRuler.currentGrid.keyboardSelectedCell = {row = gridRow, col = gridCol}
                local cell = self.gameRuler.currentGrid:getCell(gridRow, gridCol)
                if cell then
                    -- Clear hover cell first to ensure sound plays on transition
                    self.gameRuler.currentGrid.mouseHoverCell = nil
                    self.gameRuler.currentGrid:showHoverIndicator(cell)
                end

                self.gameRuler.currentGrid.uiNavigationActive = false
                HOVER_INDICATOR_STATE.IS_HIDDEN = false
            end
            return true
        end

        -- Check if new position is valid (within 1-4 range)
        if newRow >= 1 and newRow <= 4 and newCol >= 1 and newCol <= 4 then
            -- Find the UI element at the new position
            local newElementIndex = self:findUIElementByPosition(newPanel, newRow, newCol)

            if newElementIndex then
                -- Update current element and persistent navigation state
                self.currentUIElementIndex = newElementIndex
                self.activeUIElement = self.uiElements[self.currentUIElementIndex]
                self.currentNavRow = newRow
                self.currentNavCol = newCol
                self.currentNavPanel = newPanel

                self:syncKeyboardAndMouseFocus()
                return true
            end
        end
    elseif key == "return" or key == "space" then

        if GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and self.gameRuler and self.gameRuler.currentPlayer == GAME.CURRENT.AI_PLAYER_NUMBER then
            return true
        end

        -- Execute button action
        if self.activeUIElement and self.activeUIElement.action then
            local result = self.activeUIElement.action()

            if result == true then
                return true
            end
        end
        return true
    end

    return false
end

-- Helper function to find UI element by grid position
function uiClass:findUIElementByPosition(panel, row, col)
    -- Calculate the index of the unit in the panel (1-16)
    local targetIndex = ((row - 1) * 4) + col
    
    -- Find UI element matching the position
    for i, element in ipairs(self.uiElements) do
        if element.type == "supplyUnit" and element.unitData then
            if element.unitData.panelPlayer == panel and element.unitData.index == targetIndex then
                return i
            end
        end
    end
    
    return nil
end

function uiClass:syncKeyboardAndMouseFocus()
    -- print("DEBUG: syncKeyboardAndMouseFocus called - navigationMode:", self.navigationMode, "uIkeyboardNavigationActive:", self.uIkeyboardNavigationActive, "activeUIElement:", self.activeUIElement and self.activeUIElement.name or "nil")
    
    if self.navigationMode == "ui" and self.uIkeyboardNavigationActive and self.activeUIElement then
        self:clearHoveredInfo()
        
        -- Clear game log panel hover state when focusing on other elements
        if self.activeUIElement.name ~= "gameLogPanel" then
            self:clearGameLogPanelHover()
        end

        -- Play sound effect for supply panel navigation changes
        if self.activeUIElement.type == "supplyUnit" then
            -- Check if this is a different supply unit than the previous one
            local currentSupplyKey = nil
            if self.activeUIElement.unitData then
                currentSupplyKey = self.activeUIElement.unitData.panelPlayer .. "_" .. self.activeUIElement.unitData.index
            end

            if not self.lastSupplyKey or self.lastSupplyKey ~= currentSupplyKey then
                -- Play supply panel beep sound
                self:playSupplyBeep()
                self.lastSupplyKey = currentSupplyKey
            end

            -- IMPORTANT: When focusing supply items, clear last focused button so
            -- that button focus sound plays again when returning to a button
            self.lastKeyboardFocusedButton = nil

            local unitData = self.activeUIElement.unitData
            if unitData then
                local panelFaction = self:getSupplyFactionForPanel(unitData.panelPlayer)

                if unitData.isEmpty then
                    self.hoveredUnit = nil
                    self.hoveredUnitPlayer = panelFaction or 0
                    self.hoveredUnitIndex = unitData.index

                    if not self.selectedUnit then
                        local emptyInfo = {
                            status = "Empty Supply Slot",
                            panel = (unitData.panelPlayer == 1) and "Left Panel" or "Right Panel"
                        }
                        self:setContent(emptyInfo, self.playerThemes[panelFaction] or self.playerThemes[0])
                        self.forceInfoPanelDefault = false
                    end
                else
                    self.hoveredUnit = unitData.unit
                    self.hoveredUnitPlayer = panelFaction or 0
                    self.hoveredUnitIndex = unitData.index
                    
                    -- Store the flip type for the hovered supply icon (must match supply icon calculation)
                    -- Use the same iconFaction logic as drawSupplyUnitIcon
                    local iconFaction = unitData.panelPlayer
                    if GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL then
                        if unitData.panelPlayer == 1 then
                            iconFaction = self.playerSupply1Faction or unitData.panelPlayer
                        elseif unitData.panelPlayer == 2 then
                            iconFaction = self.playerSupply2Faction or unitData.panelPlayer
                        end
                    end
                    local tintPlayer = iconFaction
                    local seed = unitData.index * 1000 + (tintPlayer or 1) * 100
                    self.hoveredSupplyFlipType = randomGen.deterministicRandom(seed, 1, 4)

                    if not self.selectedUnit and unitData.unit then
                        local unitInfo = self:createUnitInfoFromUnit(unitData.unit, panelFaction)
                        self:setContent(unitInfo, self.playerThemes[panelFaction] or self.playerThemes[0])
                        self.forceInfoPanelDefault = false
                    end
                end
            end
        end
        
        -- Play sound effect for button navigation changes
        if self.activeUIElement.type == "button" then
            local buttonName = self.activeUIElement.name
            if buttonName ~= self.lastKeyboardFocusedButton then
                -- Play button beep sound (phase/MOM buttons)
                self:playButtonBeep()
                self.lastKeyboardFocusedButton = buttonName
                
                -- Clear supply key tracking when focusing on buttons to ensure sound plays when returning to supply panels
                self.lastSupplyKey = nil
                
                -- Also update the hover tracking for mouse compatibility
                if buttonName == "phaseButton" then
                    self.lastPhaseButtonHover = true
                elseif buttonName == "surrenderButton" then
                    self.lastSurrenderButtonHover = true
                elseif self:isReactionButtonName(buttonName) then
                    self.onlineReactionButtons.lastHoverName = buttonName
                end
            end
        elseif self.activeUIElement.type == "panel" then
            local panelName = self.activeUIElement.name
            if panelName ~= self.lastKeyboardFocusedPanel then
                -- Play button beep sound for panel navigation (same as buttons)
                self:playButtonBeep()
                self.lastKeyboardFocusedPanel = panelName
                
                -- Clear supply key tracking when focusing on panels
                self.lastSupplyKey = nil
            end

            -- If focusing a panel (e.g., gameLogPanel), normalize Game Over button colors
            -- so previously focused buttons (main menu / toggle / return) visually lose focus
            if self.gameOverPanel then
                if self.gameOverPanel.button then
                    self.gameOverPanel.button.currentColor = self.colors.button
                end
                if self.gameOverPanel.toggleButton then
                    self.gameOverPanel.toggleButton.currentColor = self.colors.button
                end
                if self.gameOverPanel.returnButton then
                    self.gameOverPanel.returnButton.currentColor = self.gameOverPanel.returnButton.normalColor or self.colors.button
                end
            end

            -- IMPORTANT: When focusing panels, clear last focused button so
            -- that button focus sound plays again when returning to any button
            self.lastKeyboardFocusedButton = nil
        else
            -- If not focusing on a button or panel, clear the last focused states
            self.lastKeyboardFocusedButton = nil
            self.lastKeyboardFocusedPanel = nil
            -- Reset button hover states when losing keyboard focus
            self.lastPhaseButtonHover = false
            self.lastSurrenderButtonHover = false
            self.onlineReactionButtons.lastHoverName = nil
        end
    else
        -- Clear game log panel hover state when not in UI navigation mode
        self:clearGameLogPanelHover()

        if self.activeUIElement and self.activeUIElement.type == "button" and self.activeUIElement.name == "phaseButton" then
            self.selectedUnit = nil
            self.selectedUnitPlayer = nil
            self.selectedUnitIndex = nil
            self.selectedUnitCoordOnPanel = nil
            self:setContent(nil)
            self.forceInfoPanelDefault = true
            return true
        end
        self.forceInfoPanelDefault = false

        -- Handle game over buttons specially
        if self.gameRuler and self.gameRuler.currentPhase == "gameOver" then
            -- When navigating game over buttons, clear content and just focus the button
            local activeElement = self.activeUIElement
            if activeElement and activeElement.type == "button" and self.gameOverPanel then
                -- For buttons like mainMenuButton, toggleButton, or returnButton
                self.selectedUnit = nil
                self.selectedUnitPlayer = nil
                self.selectedUnitIndex = nil
                self.selectedUnitCoordOnPanel = nil
                self:setContent(nil)

                -- Reset all game over button colors first
                if self.gameOverPanel.button then
                    self.gameOverPanel.button.currentColor = self.colors.button
                end
                if self.gameOverPanel.toggleButton then
                    self.gameOverPanel.toggleButton.currentColor = self.colors.button
                end
                if self.gameOverPanel.returnButton then
                    self.gameOverPanel.returnButton.currentColor = self.colors.button
                end

                -- Auto-update button colors based on focus
                if activeElement.name == "mainMenuButton" and self.gameOverPanel.button then
                    self.gameOverPanel.button.currentColor = self.gameOverPanel.button.hoverColor
                elseif activeElement.name == "toggleButton" and self.gameOverPanel.toggleButton then
                    self.gameOverPanel.toggleButton.currentColor = self.gameOverPanel.toggleButton.hoverColor
                elseif activeElement.name == "returnButton" and self.gameOverPanel.returnButton then
                    self.gameOverPanel.returnButton.currentColor = self.gameOverPanel.returnButton.hoverColor
                end
                return
            end
        end

        if self.activeUIElement and self.activeUIElement.type == "supplyUnit" and self.activeUIElement.unitData then
            local unitData = self.activeUIElement.unitData

            -- If the slot is empty and no unit is selected, show default info
            if unitData.isEmpty and not self.selectedUnit then
                self:setContent(nil)
                self.forceInfoPanelDefault = true
                return true
            end

            -- Otherwise, show unit info as usual
            self.hoveredUnit = unitData.unit
            local panelFaction = self:getSupplyFactionForPanel(unitData.panelPlayer)
            self.hoveredUnitPlayer = panelFaction or (unitData.panelPlayer or unitData.player)
            self.hoveredUnitIndex = unitData.index
            
            -- Store the flip type for the hovered supply icon (must match supply icon calculation)
            -- Use the same iconFaction logic as drawSupplyUnitIcon
            local iconFaction = unitData.panelPlayer
            if GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL then
                if unitData.panelPlayer == 1 then
                    iconFaction = self.playerSupply1Faction or unitData.panelPlayer
                elseif unitData.panelPlayer == 2 then
                    iconFaction = self.playerSupply2Faction or unitData.panelPlayer
                end
            end
            local tintPlayer = iconFaction
            local seed = unitData.index * 1000 + (tintPlayer or 1) * 100
            self.hoveredSupplyFlipType = randomGen.deterministicRandom(seed, 1, 4)

            if not self.selectedUnit and unitData.unit then
                local unitInfo = self:createUnitInfoFromUnit(unitData.unit, panelFaction)
                self:setContent(unitInfo, self.playerThemes[panelFaction] or self.playerThemes[0])
            end
        end
    end
end

-- Helper function to find a unit at a specific position in a panel
function uiClass:findUnitAtPosition(panelPlayer, row, col)
    -- Get the exact target index we're looking for
    local targetIndex = ((row - 1) * 4) + col

    -- First try exact match by index and panel
    for _, unit in ipairs(self.unitPositions) do
        if unit.panelPlayer == panelPlayer and unit.index == targetIndex then
            return unit
        end
    end
    
    -- Fallback using position-based calculation
    for _, unit in ipairs(self.unitPositions) do
        if unit.panelPlayer == panelPlayer then
            -- Calculate position based on x,y coordinates for all cells including empty ones
            local baseX, baseY = nil, nil
            local cellSize = 0
            local cellFound = false
            
            -- Find base position and cell size by looking at first unit in this panel
            for _, baseUnit in ipairs(self.unitPositions) do
                if baseUnit.panelPlayer == panelPlayer then
                    baseX = baseUnit.x
                    baseY = baseUnit.y
                    cellSize = baseUnit.size
                    cellFound = true
                    break
                end
            end

            if cellFound then
                local targetX = baseX + (col-1) * (cellSize + 8)  -- 8 is the padding between cells
                local targetY = baseY + (row-1) * (cellSize + 8)

                -- Find unit at calculated position
                if math.abs(unit.x - targetX) < 5 and math.abs(unit.y - targetY) < 5 then
                    return unit
                end
            end
        end
    end

    local targetIndex = ((row - 1) * 4) + (col - 1) + 1
    local count = 0

    for _, unit in ipairs(self.unitPositions) do
        if unit.panelPlayer == panelPlayer then
            count = count + 1
            if count == targetIndex then
                return unit
            end
        end
    end

    return nil
end

-- Helper function to find UI element for a given unit
function uiClass:findUIElementForUnit(unitPos)
    for i, element in ipairs(self.uiElements) do
        if element.type == "supplyUnit" and 
           element.unitData and 
           element.x == unitPos.x and 
           element.y == unitPos.y then
            return i
        end
    end
    return nil
end

function uiClass:resetButtonHighlights()
    if self.phaseButton then
        self.phaseButton.currentColor = self.phaseButton.normalColor
    end

    if self.surrenderButton then
        self.surrenderButton.currentColor = self.surrenderButton.normalColor
    end

    if self.scenarioBackButton then
        self.scenarioBackButton.currentColor = self.scenarioBackButton.normalColor
    end
    if self.scenarioRetryButton then
        self.scenarioRetryButton.currentColor = self.scenarioRetryButton.normalColor
    end
    self.lastScenarioBackButtonHover = false
    self.lastScenarioRetryButtonHover = false

    for _, button in ipairs(self:getOnlineReactionButtons()) do
        button.currentColor = cloneColor(button.normalColor)
        button.focused = false
    end
    self.onlineReactionButtons.lastHoverName = nil

    -- Clear game log panel focus state
    self:clearGameLogPanelHover()

    if self.gameOverPanel then
        if self.gameOverPanel.button then
            self.gameOverPanel.button.currentColor = self.colors.button
        end
        if self.gameOverPanel.toggleButton then
            self.gameOverPanel.toggleButton.currentColor = self.colors.button
        end
        if self.gameOverPanel.returnButton then
            self.gameOverPanel.returnButton.currentColor = self.colors.button
        end
    end
end

function uiClass:drawKeyboardNavigationHighlight()
    if not self.uIkeyboardNavigationActive or not self.activeUIElement then
        return true
    end

    local element = self.activeUIElement

    if element.type == "button" then
        -- Button highlighting logic remains the same
        if element.name == "phaseButton" and self.phaseButton then
            self.phaseButton.currentColor = self.phaseButton.hoverColor
        elseif element.name == "surrenderButton" and self.surrenderButton then
            self.surrenderButton.currentColor = self.surrenderButton.hoverColor
        elseif element.name == "scenarioBackButton" and self.scenarioBackButton then
            self.scenarioBackButton.currentColor = self.scenarioBackButton.hoverColor
        elseif element.name == "scenarioRetryButton" and self.scenarioRetryButton then
            self.scenarioRetryButton.currentColor = self.scenarioRetryButton.hoverColor
        elseif self:isReactionButtonName(element.name) then
            local reactionButton = self:getOnlineReactionButtonByName(element.name)
            if reactionButton and reactionButton.disabledVisual ~= true then
                reactionButton.currentColor = cloneColor(reactionButton.hoverColor)
                reactionButton.focused = true
            end
        elseif element.name == "mainMenuButton" and self.gameOverPanel.button then
            self.gameOverPanel.button.currentColor = self.gameOverPanel.button.hoverColor
        elseif element.name == "toggleButton" and self.gameOverPanel.toggleButton then
            self.gameOverPanel.toggleButton.currentColor = self.gameOverPanel.toggleButton.hoverColor
        elseif element.name == "returnButton" and self.gameOverPanel.returnButton then
            self.gameOverPanel.returnButton.currentColor = self.gameOverPanel.returnButton.hoverColor
        end
    elseif element.type == "supplyUnit" then
        -- UPDATED: Show PNG indicator for keyboard navigation with WHITE color (same as grid)
        if self.uiSelectionPointerImage then
            -- WHITE COLOR (same as grid)
            local indicatorColor = {1.0, 1.0, 1.0, 0.8}  -- White color (same as grid)
            
            -- Calculate indicator position and size - LARGER than unit icon
            local indicatorSize = element.width * 1.2  -- 20% larger than the unit icon
            local centerX = element.x + element.width / 2
            local centerY = element.y + element.height / 2
            
            -- NO ANIMATION - static display (same as hover)
            local alpha = 0.8
            
            -- Apply white color and alpha
            love.graphics.setColor(indicatorColor[1], indicatorColor[2], indicatorColor[3], alpha)
            
            -- Draw the PNG indicator (no scale animation)
            love.graphics.draw(
                self.uiSelectionPointerImage,
                centerX, centerY,
                0, -- rotation
                indicatorSize / self.uiSelectionPointerImage:getWidth(),
                indicatorSize / self.uiSelectionPointerImage:getHeight(),
                self.uiSelectionPointerImage:getWidth() / 2,  -- origin X (center)
                self.uiSelectionPointerImage:getHeight() / 2   -- origin Y (center)
            )
            
            -- Reset color
            love.graphics.setColor(1, 1, 1, 1)
        end
    end

    -- Reset line width
    love.graphics.setLineWidth(1)
end

function uiClass:handleClickOnSupplyUnit(unitPos)
    local panelFaction = self:getSupplyFactionForPanel(unitPos.panelPlayer)
    local actualPlayer = self:getSupplyOwnerForPanel(unitPos.panelPlayer)

    self.selectedUnit = unitPos.unit
    self.selectedUnitPlayer = panelFaction
    self.selectedUnitOwner = actualPlayer
    self.selectedUnitIndex = unitPos.index
    self.selectedUnitCoordOnPanel = { x = unitPos.x, y = unitPos.y }

    local unitInfo = self:createUnitInfoFromUnit(unitPos.unit, panelFaction)
    self.infoPanel.title = string.upper(unitPos.unit.name or "Unit")
    self:setContent(unitInfo, self.playerThemes[panelFaction])

    if self.gameRuler then
        if self.gameRuler.currentPhase == "deploy1_units" or self.gameRuler.currentPhase == "deploy2_units" then
            if actualPlayer == self.gameRuler.currentPlayer then
                self.gameRuler.initialDeployment = self.gameRuler.initialDeployment or {}
                self.gameRuler.initialDeployment.selectedUnitIndex = unitPos.index

                -- Highlight available cells around Commandant
                if self.gameRuler.initialDeployment.availableCells then
                    self.gameRuler.currentGrid:highlightPositions(
                        self.gameRuler.initialDeployment.availableCells,
                        {r=0.2, g=0.8, b=0.2, a=0.3}
                    )
                end
            end

        elseif self.gameRuler.currentPhase == "turn" and self.gameRuler.currentTurnPhase == "supply" then
            if actualPlayer == self.gameRuler.currentPlayer and not self.gameRuler.hasDeployedThisTurn then
                self.gameRuler.supplyUnitSelection = {
                    unitIndex = unitPos.index
                }

                -- Highlight valid deployment positions
                if self.gameRuler.supplyDeploymentPositions then
                    self.gameRuler.currentGrid:highlightPositions(
                        self.gameRuler.supplyDeploymentPositions,
                        {r=0.2, g=0.8, b=0.2, a=0.3}
                    )
                end
            end
        end
    end
end

-- Draw a simple elliptical contact shadow under non-flying units
function uiClass:drawUnitShadow(unitIcon, iconX, iconY, scaleX, scaleY, unit)
    -- Check if unit can fly - no shadow for flying units
    if unit and unit.fly then
        return
    end
    
    -- Per-unit shadow configuration
    local shadowConfig = {
        widthScale = 0.35,    -- Default: 35% of unit width
        heightScale = 0.25,   -- Default: height relative to width
        offsetX = 0,          -- Horizontal offset from center
        offsetY = 0,          -- Vertical offset from bottom
        intensity = 0.1      -- Shadow darkness (0-1)
    }
    
    -- Override defaults for specific units
    if unit and unit.name then
        local unitName = unit.name
        if unitName == "Crusher" then
            shadowConfig.widthScale = 0.44
            shadowConfig.heightScale = 0.36
            shadowConfig.offsetY = -12
        elseif unitName == "Earthstalker" then
            shadowConfig.widthScale = 0.42
            shadowConfig.heightScale = 0.28
            shadowConfig.offsetY = -8
        elseif unitName == "Bastion" then
            shadowConfig.widthScale = 0.42
            shadowConfig.heightScale = 0.30
            shadowConfig.offsetY = -12
        elseif unitName == "Artillery" then
            shadowConfig.widthScale = 0.44
            shadowConfig.heightScale = 0.28
            shadowConfig.offsetY = -18
        elseif unitName == "Commandant" then
            shadowConfig.widthScale = 0.40
            shadowConfig.heightScale = 0.28
            shadowConfig.offsetY = -8
        elseif unitName == "Rock" then
            shadowConfig.widthScale = 0.34
            shadowConfig.heightScale = 0.38
            shadowConfig.offsetY = -14
        end
    end
    
    -- Calculate shadow dimensions
    local iconWidth = unitIcon:getWidth() * scaleX
    local iconHeight = unitIcon:getHeight() * scaleY
    local shadowWidth = iconWidth * shadowConfig.widthScale
    local shadowHeight = shadowWidth * shadowConfig.heightScale
    
    -- Position shadow with per-unit offsets
    local shadowX = iconX + iconWidth * 0.5 + shadowConfig.offsetX
    local shadowY = iconY + iconHeight - shadowHeight + shadowConfig.offsetY
    
    -- Draw very soft elliptical shadow with smooth gradient (more layers)
    love.graphics.push()
    love.graphics.translate(shadowX, shadowY)
    
    -- Draw many ellipses with very gradual alpha falloff for ultra-soft edges
    local segments = 24
    local layers = 8  -- More layers = softer gradient
    for i = layers, 1, -1 do
        local scale = i / layers
        -- Smooth exponential falloff for natural soft shadow
        local alpha = shadowConfig.intensity * (scale ^ 2.5) * (1 - scale * 0.3)
        love.graphics.setColor(0, 0, 0, alpha)
        love.graphics.ellipse("fill", 0, 0, shadowWidth * scale, shadowHeight * scale, segments)
    end
    
    love.graphics.pop()
    love.graphics.setColor(1, 1, 1, 1)
end

return uiClass
