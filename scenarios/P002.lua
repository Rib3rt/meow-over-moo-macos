-- Promoted Scenario Mode level. Scenario-only data; no standard AI dependency.
return {
    id = "P002",
    name = "Scenario P002",
    objectiveMessage = "Blue to move. Destroy the enemy Commandant within 3 turns.",
    objectiveText = "Blue to move. Destroy the enemy Commandant within 3 turns.",
    objectiveType = "destroy_commandant",
    promotion = {
        approved = true,
        originalExportId = "Scenario#20260505171632-565",
        source = "scenario_editor_manual_export_promoted_to_public_slot",
        state = "promoted"
    },
    scenarioRedPolicy = {
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_a_support"
        },
        policy = "scenarioRedPolicy",
        policyHash = "red_policy_v2_plan2_static_2026_05_03",
        policyVersion = "scenario_red_policy.v2",
        requiredCells = {
            {
                col = 3,
                row = 2
            },
            {
                col = 7,
                row = 2
            },
            {
                col = 3,
                row = 3
            },
            {
                col = 7,
                row = 3
            },
            {
                col = 4,
                row = 4
            }
        },
        runtime = "scenarioRedRuntime",
        seed = 1781346111
    },
    sideToMove = "Blue",
    startSnapshot = {
        boardUnits = {
            {
                col = 3,
                currentHp = 4,
                hasActed = false,
                name = "Artillery",
                player = 1,
                row = 3,
                scenarioUnitId = "blue_a_support",
                startingHp = 5,
                turnActions = {}
            },
            {
                col = 7,
                currentHp = 4,
                hasActed = false,
                name = "Cloudstriker",
                player = 1,
                row = 6,
                scenarioUnitId = "blue_finisher",
                startingHp = 4,
                turnActions = {}
            },
            {
                col = 4,
                currentHp = 3,
                hasActed = false,
                name = "Commandant",
                player = 2,
                row = 2,
                scenarioUnitId = "red_commandant",
                startingHp = 12,
                turnActions = {}
            },
            {
                col = 3,
                currentHp = 1,
                hasActed = false,
                name = "Earthstalker",
                player = 2,
                row = 5,
                scenarioUnitId = "red_support_threat",
                startingHp = 3,
                turnActions = {}
            },
            {
                col = 5,
                currentHp = 2,
                hasActed = false,
                name = "Rock",
                player = 0,
                row = 2,
                scenarioUnitId = "neutral_rock",
                startingHp = 5,
                turnActions = {}
            },
            {
                col = 4,
                currentHp = 5,
                hasActed = false,
                name = "Rock",
                player = 0,
                row = 3,
                scenarioUnitId = "neutral_shortcut_rock",
                startingHp = 5,
                turnActions = {}
            },
            {
                col = 6,
                currentHp = 2,
                hasActed = false,
                name = "Crusher",
                player = 2,
                row = 6,
                scenarioUnitId = "editor_2_crusher_6_6_7",
                startingHp = 4,
                turnActions = {}
            },
            {
                col = 4,
                currentHp = 2,
                hasActed = false,
                name = "Crusher",
                player = 2,
                row = 5,
                scenarioUnitId = "editor_2_crusher_5_4_8",
                startingHp = 4,
                turnActions = {}
            }
        },
        commandHubPlacementReady = true,
        commandHubPositions = {
            [2] = {
                col = 4,
                row = 2
            }
        },
        currentPhase = "turn",
        currentPlayer = 1,
        currentTurn = 1,
        currentTurnActions = 0,
        currentTurnPhase = "actions",
        drawGame = false,
        factionAssignments = {
            "local_player_1",
            "local_ai_1"
        },
        gridSetupComplete = {
            true,
            true
        },
        hasDeployedThisTurn = true,
        initialDeployment = {
            availableCells = {},
            completedDeployments = 0,
            requiredDeployments = 0
        },
        integritySignature = {
            boardByPlayer = {
                [0] = 2,
                [1] = 2,
                [2] = 4
            },
            boardUnitTotal = 8,
            commandants = {
                0,
                1
            },
            supplyByPlayer = {
                0,
                0
            }
        },
        logicRngSeed = 13012,
        logicRngState = 13012,
        maxActionsPerTurn = 2,
        neutralBuildings = {},
        neutralBuildingsPlaced = 0,
        noMoreUnitsGameOver = false,
        playerSupplies = {
            {},
            {}
        },
        targetRows = {
            3,
            4,
            5,
            6
        },
        tempCommandHubPosition = {},
        turnHadInteraction = false,
        turnOrder = {
            1,
            2
        },
        turnsWithoutDamage = 0,
        usedRows = {},
        version = 4
    },
    status = "PROMOTED",
    turnLimitRounds = 3
}
