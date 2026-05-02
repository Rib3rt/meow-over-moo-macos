local M = {}
local logger = require("logger")

function M.mixin(aiClass, shared)
    local unitsInfo = shared.unitsInfo
    local aiInfluence = shared.aiInfluence
    local randomGen = shared.randomGen
    local aiConfig = shared.aiConfig

    local DEFAULT_AI_PARAMS = shared.DEFAULT_AI_PARAMS
    local DEFAULT_SCORE_PARAMS = shared.DEFAULT_SCORE_PARAMS
    local DEFAULT_UNIT_PROFILES = shared.DEFAULT_UNIT_PROFILES
    local RUNTIME_DEFAULTS = shared.RUNTIME_DEFAULTS
    local ZERO = shared.ZERO
    local MIN_HP = shared.MIN_HP
    local DEFAULT_TURN = shared.DEFAULT_TURN
    local DEFAULT_GRID_SIZE = shared.DEFAULT_GRID_SIZE
    local DISTANCE_FALLBACK = shared.DISTANCE_FALLBACK
    local PLAYER_INDEX_SUM = shared.PLAYER_INDEX_SUM
    local ONE = shared.ONE
    local TWO = shared.TWO
    local THREE = shared.THREE
    local FOUR = shared.FOUR
    local FIVE = shared.FIVE
    local SIX = shared.SIX
    local SEVEN = shared.SEVEN
    local EIGHT = shared.EIGHT
    local TEN = shared.TEN
    local NEGATIVE_MIN_HP = shared.NEGATIVE_MIN_HP
    local NEGATIVE_ONE = shared.NEGATIVE_ONE
    local BASE_AI_REFERENCE = shared.BASE_AI_REFERENCE
    local RULE_CONTRACT = shared.RULE_CONTRACT
    local SETUP_RULE_CONTRACT = shared.SETUP_RULE_CONTRACT
    local ACTION_RULE_CONTRACT = shared.ACTION_RULE_CONTRACT
    local TURN_RULE_CONTRACT = shared.TURN_RULE_CONTRACT
    local PERFORMANCE_RULE_CONTRACT = shared.PERFORMANCE_RULE_CONTRACT
    local DEFAULT_POSITIONAL_COMPONENT_WEIGHTS = shared.DEFAULT_POSITIONAL_COMPONENT_WEIGHTS
    local STRATEGY_INTENT = shared.STRATEGY_INTENT
    local STRATEGY_ROLE_ORDER = shared.STRATEGY_ROLE_ORDER

    local valueOr = shared.valueOr
    local deepCopyValue = shared.deepCopyValue
    local getMonotonicTimeSeconds = shared.getMonotonicTimeSeconds
    local deepMerge = shared.deepMerge
    local hashPosition = shared.hashPosition
    local buildMovePatternKey = shared.buildMovePatternKey

    local function buildPhaseKey(ai, info)
        if not info then
            return "unknown"
        end
        return table.concat({
            tostring((GAME and GAME.CURRENT and GAME.CURRENT.TURN) or "?"),
            tostring(info.currentPlayer or "?"),
            tostring(info.currentPhase or "?"),
            tostring(info.turnPhaseName or "?"),
            tostring(ai and ai.factionId or "?")
        }, ":")
    end

    local function nowSeconds()
        if love and love.timer and love.timer.getTime then
            return love.timer.getTime()
        end
        return os.clock()
    end

    local function setAiPanelStatus(ai, phaseKey, status)
        if not (GAME and GAME.CURRENT) then
            return
        end
        GAME.CURRENT.AI_PANEL_STATUS = {
            phaseKey = phaseKey,
            player = ai and ai.factionId or nil,
            status = status,
            updatedAt = nowSeconds()
        }
    end

    local function clearAiPanelStatus(ai, phaseKey)
        if not (GAME and GAME.CURRENT and GAME.CURRENT.AI_PANEL_STATUS) then
            return
        end
        local current = GAME.CURRENT.AI_PANEL_STATUS
        if current.phaseKey == phaseKey and current.player == (ai and ai.factionId or nil) then
            GAME.CURRENT.AI_PANEL_STATUS = nil
        end
    end

    local function schedulerConfigFor(ai)
        return ((ai and ai.AI_PARAMS or {}).SCHEDULER or {})
    end

    local function schedulerNumber(ai, key, fallback)
        local value = schedulerConfigFor(ai)[key]
        if type(value) == "number" then
            return value
        end
        return fallback
    end

    local function schedulerEnabled(ai, key, fallback)
        local value = schedulerConfigFor(ai)[key]
        if value == nil then
            return fallback
        end
        return value == true
    end

    function aiClass:startAsyncActionsDecision(state, phaseKey)
        local scheduler = schedulerConfigFor(self)
        if schedulerEnabled(self, "AI_DECISION_ASYNC_ENABLED", false) ~= true then
            return false
        end
        if not (coroutine and coroutine.create and coroutine.resume and coroutine.status) then
            return false
        end
        if self.isTournamentAiEnabled and not self:isTournamentAiEnabled() then
            return false
        end
        if self._aiDecisionJob then
            if self._aiDecisionJob.phaseKey == phaseKey then
                return true
            end
            self._aiDecisionJob.cancelled = true
            self._aiDecisionJob = nil
        end

        local sliceMs = math.max(1, schedulerNumber(self, "AI_DECISION_SLICE_MS", 6))
        local resumeDelay = math.max(0, schedulerNumber(self, "AI_DECISION_RESUME_DELAY", 0))
        local pollDelay = math.max(0.01, schedulerNumber(self, "ANIMATION_POLL_INTERVAL", 0.05))
        local slowWallMs = math.max(0, schedulerNumber(self, "AI_DECISION_MAX_WALL_MS", 1500))
        local asyncSoftBudget = schedulerNumber(self, "AI_DECISION_ASYNC_SOFT_BUDGET_MS", nil)
        local asyncHardBudget = schedulerNumber(self, "AI_DECISION_ASYNC_HARD_BUDGET_MS", nil)

        local job = {
            phaseKey = phaseKey,
            state = state,
            startedAt = nowSeconds(),
            computeMs = 0,
            slices = 0,
            currentSliceStart = nil,
            loggedSlow = false,
            cancelled = false
        }

        local function computeElapsedMs()
            local elapsed = job.computeMs
            if job.currentSliceStart then
                elapsed = elapsed + ((nowSeconds() - job.currentSliceStart) * 1000)
            end
            return elapsed
        end

        local function shouldYield()
            if not job.currentSliceStart then
                return false
            end
            return ((nowSeconds() - job.currentSliceStart) * 1000) >= sliceMs
        end

        local co = coroutine.create(function()
            return self:getBestSequence(state, {
                cooperative = true,
                budgetElapsedMs = computeElapsedMs,
                shouldYield = shouldYield,
                tournamentSoftBudgetMs = asyncSoftBudget,
                tournamentHardBudgetMs = asyncHardBudget
            })
        end)
        job.co = co
        self._aiDecisionJob = job
        setAiPanelStatus(self, phaseKey, "thinking")

        local resumeJob
        local function scheduleNext(delay)
            if self.gameRuler and self.gameRuler.scheduleAction then
                self.gameRuler:scheduleAction(delay or resumeDelay, resumeJob)
            end
        end

        resumeJob = function()
            if self._aiDecisionJob ~= job or job.cancelled then
                return
            end

            local livePhaseInfo = nil
            if self.gameRuler and self.gameRuler.getCurrentPhaseInfo then
                livePhaseInfo = self.gameRuler:getCurrentPhaseInfo()
            end
            if buildPhaseKey(self, livePhaseInfo) ~= phaseKey then
                job.cancelled = true
                self._aiDecisionJob = nil
                self.isProcessingTurn = false
                clearAiPanelStatus(self, phaseKey)
                return
            end

            if self.gameRuler
                and self.gameRuler.hasActiveAnimations
                and self.gameRuler:hasActiveAnimations() then
                scheduleNext(pollDelay)
                return
            end

            if slowWallMs > 0 and not job.loggedSlow then
                local wallMs = (nowSeconds() - job.startedAt) * 1000
                if wallMs >= slowWallMs then
                    job.loggedSlow = true
                    logger.warn("AI", string.format(
                        "AI_ASYNC_DECISION_SLOW player=%s phase=%s wallMs=%.1f computeMs=%.1f sliceMs=%.1f",
                        tostring(self.factionId),
                        tostring(phaseKey),
                        wallMs,
                        computeElapsedMs(),
                        sliceMs
                    ))
                end
            end

            job.currentSliceStart = nowSeconds()
            local ok, sequenceOrYield = coroutine.resume(co)
            local sliceElapsed = (nowSeconds() - job.currentSliceStart) * 1000
            job.computeMs = job.computeMs + sliceElapsed
            job.slices = job.slices + 1
            job.currentSliceStart = nil

            if not ok then
                self._aiDecisionJob = nil
                self.isProcessingTurn = false
                self.actionsPhaseStarted = false
                setAiPanelStatus(self, phaseKey, "done")
                logger.warn("AI", string.format(
                    "AI_ASYNC_DECISION_ERROR player=%s phase=%s error=%s",
                    tostring(self.factionId),
                    tostring(phaseKey),
                    tostring(sequenceOrYield)
                ))
                return
            end

            if coroutine.status(co) == "dead" then
                self._aiDecisionJob = nil
                setAiPanelStatus(self, phaseKey, "done")
                local actionCount = type(sequenceOrYield) == "table" and #sequenceOrYield or 0
                logger.warn("AI", string.format(
                    "AI_ASYNC_DECISION_DONE player=%s phase=%s wallMs=%.1f computeMs=%.1f slices=%d actions=%d",
                    tostring(self.factionId),
                    tostring(phaseKey),
                    (nowSeconds() - job.startedAt) * 1000,
                    job.computeMs,
                    job.slices,
                    actionCount
                ))
                self:executeActionsSequence(sequenceOrYield or {})
                return
            end

            scheduleNext(resumeDelay)
        end

        scheduleNext(0)
        return true
    end

    --[[
    SECTION: TURN PHASE ORCHESTRATION
    Schedules AI processing for each phase after a short delay so animations can finish cleanly.
    - Resets per-turn flags when the AI regains control.
    - Delegates to specific handlers for setup, deployment, and action phases.
    ]]
    function aiClass:handleAITurn(phaseInfo, grid)
        -- Skip processing while any grid animation/effect runs.
        if self.gameRuler
            and self.gameRuler.hasActiveAnimations
            and self.gameRuler:hasActiveAnimations() then
            return
        end

        local turnFlowConfig = self:getTurnFlowScoreConfig()
        local defaultTurnFlowConfig = DEFAULT_SCORE_PARAMS.TURN_FLOW or {}
        local startDelay = valueOr(turnFlowConfig.START_DELAY, valueOr(defaultTurnFlowConfig.START_DELAY, ZERO))

        local scheduledKey = buildPhaseKey(self, phaseInfo)
        if self._scheduledAITurnKey == scheduledKey then
            return
        end
        self._scheduledAITurnKey = scheduledKey

        self.gameRuler:scheduleAction(startDelay, function()
            self._scheduledAITurnKey = nil

            -- The scheduled callback can fire after a new visual action started.
            -- Recheck here so a stale AI start cannot freeze an in-flight animation.
            if self.gameRuler
                and self.gameRuler.hasActiveAnimations
                and self.gameRuler:hasActiveAnimations() then
                return
            end

            local livePhaseInfo = phaseInfo
            if self.gameRuler and self.gameRuler.getCurrentPhaseInfo then
                livePhaseInfo = self.gameRuler:getCurrentPhaseInfo()
            end
            if buildPhaseKey(self, livePhaseInfo) ~= scheduledKey then
                return
            end
            phaseInfo = livePhaseInfo

            -- Route handling based on the current game phase.
            if phaseInfo.currentPhase == "setup" and self.factionId == ONE then
                self:handleAINeutralBuildingPlacement()

            elseif phaseInfo.currentPhase == "deploy1" or phaseInfo.currentPhase == "deploy2" then
                self:handleAICommandHubPlacement()

            elseif phaseInfo.currentPhase == "deploy1_units" or phaseInfo.currentPhase == "deploy2_units" then
                self:handleAIInitialDeployment()

            elseif phaseInfo.currentPhase == "turn" then
                if phaseInfo.turnPhaseName == "actions" then

                    local currentTurn = GAME.CURRENT and GAME.CURRENT.TURN or nil

                    -- Reset per-turn flags when the AI no longer controls the phase.
                    if self.actionsPhaseStarted then
                        if (currentTurn and self.lastActionTurnProcessed and self.lastActionTurnProcessed ~= currentTurn)
                            or self.gameRuler.currentPlayer ~= self.factionId then
                            self.actionsPhaseStarted = false
                        end
                    end

                    if self.gameRuler.currentPlayer == self.factionId and not self.actionsPhaseStarted then
                        self.hasDeployedThisTurn = false
                        self.currentTurnAttackedObjectives = {}
                        self.currentTurnAttackedObjectivesLookup = {}
                        self.actionsPhaseStarted = true
                        self.lastActionTurnProcessed = currentTurn
                        local currentState = self:getStateFromGrid()
                        if not currentState or not currentState.units then
                            self.actionsPhaseStarted = false
                            self:logDecision("TurnPhase", "Skipping actions phase: state unavailable")
                            return
                        end
                        self._lastLoggedStateSnapshot = currentState
                        self._referenceResolutionState = currentState
                        local profileLabel = self:getAiProfileLabel(currentState, {
                            lock = true,
                            context = "actions_phase_start",
                            logSwitch = true
                        })

                        -- Calculate the current win probability snapshot.
                        local winPercentage = self:calculateWinningPercentage(currentState)

                        -- Refresh win-state profile controls.
                        self:updateWinPercentageProfile(currentTurn, currentState)

                        -- Refresh adaptive profile controls.
                        self:updateAdaptiveProfile(currentTurn, currentState)

                        self:logDecision("TurnPhase", "Starting actions phase", {
                            profile = profileLabel,
                            aiUnits = self:countAiUnits(currentState),
                            totalUnitsOnGrid = currentState.units and #currentState.units or ZERO,
                            winChance = string.format("%.1f%%", winPercentage)
                        })
                        if not self:startAsyncActionsDecision(currentState, scheduledKey) then
                            setAiPanelStatus(self, scheduledKey, "thinking")
                            local moveSequence = self:getBestSequence(currentState)
                            setAiPanelStatus(self, scheduledKey, "done")
                            self:executeActionsSequence(moveSequence)
                        end
                    end
                elseif phaseInfo.turnPhaseName == "commandHub" then
                    -- Commandant defense resolves separately inside nextTurn().
                    -- Skipping here avoids duplicate attacks in the same phase.

                elseif phaseInfo.turnPhaseName == "endTurn" then
                    if not (grid and grid.movingUnits and #grid.movingUnits > ZERO) then
                        self.gameRuler:performAction("confirmEndTurn")
                    end
                else
                    if not (grid and grid.movingUnits and #grid.movingUnits > ZERO) then
                        self.gameRuler:performAction("nextPhase")
                    end
                end
            end
        end)
    end

    --[[
    SECTION: STATE SYNCHRONIZATION
    Centralizes state reads and writes through aiState helpers to avoid duplication.
    - getStateFromGrid proxies to the shared state builder.
    - Guard assignments refresh after pulling a fresh snapshot.
    ]]
    function aiClass:getStateFromGrid()
        return self.aiState.getStateFromGrid(self)
    end

    function aiClass:refreshGuardAssignmentsFromGrid()
        local snapshot = self:getStateFromGrid()
        if not snapshot then
            self.guardAssignments = {}
            return
        end

        local assignments = {}
        local snapshotGuard = snapshot.guardAssignments or {}
        for _, unit in ipairs(snapshot.units or {}) do
            local key = self:getUnitKey(unit)
            if key then
                local existing = snapshotGuard[key] or (self.guardAssignments and self.guardAssignments[key])
                if existing then
                    assignments[key] = {
                        row = existing.row,
                        col = existing.col
                    }
                end
            end
        end
        self.guardAssignments = assignments
    end

    function aiClass:getUnitAtPosition(state, row, col)
        -- Proxy lookup through aiState to avoid duplication.
        return self.aiState.getUnitAtPosition(state, row, col)
    end

    function aiClass:getBoardSize(state)
        return (state and state.gridSize) or (GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE) or DEFAULT_GRID_SIZE
    end

    function aiClass:isInsideBoard(row, col, state)
        local gridSize = self:getBoardSize(state)
        return row >= ONE and row <= gridSize and col >= ONE and col <= gridSize
    end

    function aiClass:getOrthogonalDirections()
        return {
            {row = ONE, col = ZERO},
            {row = NEGATIVE_ONE, col = ZERO},
            {row = ZERO, col = ONE},
            {row = ZERO, col = NEGATIVE_ONE}
        }
    end

    local function hashPosition(pos)
        if not pos or not pos.row or not pos.col then
            return nil
        end
        return string.format("%d,%d", pos.row, pos.col)
    end

    local function buildMovePatternKey(playerId, unitName, fromRow, fromCol, toRow, toCol)
        return string.format(
            "%s:%s:%d,%d>%d,%d",
            tostring(playerId or ZERO),
            tostring(unitName or "unknown"),
            fromRow or ZERO,
            fromCol or ZERO,
            toRow or ZERO,
            toCol or ZERO
        )
    end

    --[[
    SECTION: SAFETY VALIDATION
    Guards against friendly fire scenarios before actions resolve.
    - Logs a critical error when identical player ownership is detected.
    - Returns true to abort the attack when a friendly target is identified.
    ]]
    function aiClass:isFriendlyFireAttack(attackerUnit, targetUnit)
        if not attackerUnit or not targetUnit then
            return false
        end

        -- Treat identical player ownership as a friendly fire event.
        if attackerUnit.player and targetUnit.player and attackerUnit.player == targetUnit.player then
            logger.error("AI", "CRITICAL ERROR: Friendly fire detected!")
            logger.error("AI", "  Attacker:", attackerUnit.name, "Player:", attackerUnit.player, "at", attackerUnit.row, attackerUnit.col)
            logger.error("AI", "  Target:", targetUnit.name, "Player:", targetUnit.player, "at", targetUnit.row, targetUnit.col)
            return true
        end

        return false
    end

    function aiClass:removeUnitFromState(state, row, col)
        -- Capture the unit reference before removal to handle Commandant logic.
        local unit = self.aiState.getUnitAtPosition(state, row, col)

        -- Remove through aiState to keep state mutations consistent.
        self.aiState.removeUnitFromState(state, row, col)

        if state and state.neutralBuildings then
            for i = #state.neutralBuildings, ONE, NEGATIVE_ONE do
                local building = state.neutralBuildings[i]
                if building and building.row == row and building.col == col then
                    table.remove(state.neutralBuildings, i)
                end
            end
        end

        -- Clear the Commandant hub entry when the unit was a Commandant.
        if unit and self:isHubUnit(unit) and state and state.commandHubs then
            state.commandHubs[unit.player] = nil
        end
    end

    function aiClass:deepCopyState(state)
        -- Clone the state through aiState to mirror shared logic.
        local copy = self.aiState.deepCopyState(state)

        -- Copy supply data when present so command hub resummons remain accurate.
        if state and state.supply then
            copy.supply = {
                [ONE] = {},
                [TWO] = {}
            }
            for player, units in pairs(state.supply) do
                for _, unit in ipairs(units) do
                    table.insert(copy.supply[player], {
                        name = unit.name,
                        currentHp = math.max(ZERO, unit.currentHp or ZERO),
                        startingHp = math.max(ONE, unit.startingHp or MIN_HP)
                    })
                end
            end
        end

        return copy
    end

    --[[
    SECTION: MOVEMENT QUERIES
    Delegates movement, attack, and repair calculations to ai_mobility helpers.
    - Keeps pathing logic consistent across the AI modules.
    ]]
    function aiClass:getValidMoveCells(state, row, col)
        return self.aiMovement.getValidMoveCells(self, state, row, col)
    end

    function aiClass:getValidAttackCells(state, row, col)
        return self.aiMovement.getValidAttackCells(self, state, row, col)
    end

    function aiClass:getValidRepairCells(state, row, col)
        if not state or not row or not col then
            return {}
        end

        local unit = self:getUnitAtPosition(state, row, col)
        if not unit or not self:unitHasTag(unit, "healer") then
            return {}
        end

        local repairCells = {}
        local repairRange = unitsInfo:getUnitAttackRange(unit, "GET_VALID_REPAIR_CELLS") or ONE

        for _, dir in ipairs(self:getOrthogonalDirections()) do
            for dist = ONE, repairRange do
                local targetRow = row + (dir.row * dist)
                local targetCol = col + (dir.col * dist)
                if targetRow >= ONE and targetRow <= GAME.CONSTANTS.GRID_SIZE
                    and targetCol >= ONE and targetCol <= GAME.CONSTANTS.GRID_SIZE then
                    local targetUnit = self:getUnitAtPosition(state, targetRow, targetCol)
                    if targetUnit and targetUnit.player == unit.player then
                        local currentHp = targetUnit.currentHp or targetUnit.startingHp or ONE
                        local maxHp = targetUnit.startingHp or ONE
                        if currentHp < maxHp then
                            repairCells[#repairCells + ONE] = {row = targetRow, col = targetCol}
                        end
                    end
                end
            end
        end

        return repairCells
    end

    function aiClass:hasLineOfSight(state, from, to)
        return self.aiMovement.hasLineOfSight(self, state, from, to)
    end

    function aiClass:getLinePath(from, to)
        return self.aiMovement.getLinePath(from, to)
    end

    function aiClass:canUnitReachPosition(state, unit, targetPos)
        return self.aiMovement.canUnitReachPosition(self, state, unit, targetPos)
    end

    --[[
    SECTION: CORE DECISION HELPERS
    Centralizes repeated eligibility and safety checks used across priority logic.
    ]]
end

return M
