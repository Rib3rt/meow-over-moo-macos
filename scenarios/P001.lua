-- Promoted Scenario Mode level. Scenario-only data; no standard AI dependency.
return {
    id = "P001",
    name = "Scenario P001",
    objectiveMessage = "Blue to move. Destroy the enemy Commandant within 3 turns.",
    objectiveText = "Blue to move. Destroy the enemy Commandant within 3 turns.",
    objectiveType = "destroy_commandant",
    promotion = {
        approved = true,
        originalExportId = "Scenario#20260505115547-384",
        source = "verified_export_promoted_to_public_slot",
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
                col = 5,
                row = 3
            },
            {
                col = 4,
                row = 3
            }
        },
        runtime = "scenarioRedRuntime",
        seed = 1782660757
    },
    sideToMove = "Blue",
    startSnapshot = {
        boardUnits = {
            {
                col = 5,
                currentHp = 3,
                hasActed = false,
                name = "Earthstalker",
                player = 1,
                row = 5,
                scenarioUnitId = "blue_a_support",
                startingHp = 3,
                turnActions = {}
            },
            {
                col = 4,
                currentHp = 4,
                hasActed = false,
                name = "Crusher",
                player = 1,
                row = 7,
                scenarioUnitId = "blue_finisher",
                startingHp = 4,
                turnActions = {}
            },
            {
                col = 4,
                currentHp = 4,
                hasActed = false,
                name = "Commandant",
                player = 2,
                row = 2,
                scenarioUnitId = "red_commandant",
                startingHp = 12,
                turnActions = {}
            },
            {
                col = 4,
                currentHp = 3,
                hasActed = false,
                name = "Bastion",
                player = 2,
                row = 3,
                scenarioUnitId = "red_contact_blocker",
                startingHp = 6,
                turnActions = {}
            },
            {
                col = 7,
                currentHp = 3,
                hasActed = false,
                name = "Earthstalker",
                player = 2,
                row = 5,
                scenarioUnitId = "red_support_threat",
                startingHp = 3,
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
                [0] = 0,
                [1] = 2,
                [2] = 3
            },
            boardUnitTotal = 5,
            commandants = {
                0,
                1
            },
            supplyByPlayer = {
                0,
                0
            }
        },
        logicRngSeed = 13009,
        logicRngState = 13009,
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
