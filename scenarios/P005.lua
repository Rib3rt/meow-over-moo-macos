local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P005",
    name = "Scenario P005",
    status = "PROMOTED",
    promotion = {
        state = "promoted",
        approved = true,
        source = "manual_playtest_artillery_extraction"
    },
    objectiveType = "destroy_commandant",
    objectiveMessage = "Blue to move. Destroy the enemy Commandant within 3 turns.",
    objectiveText = "Blue to move. Destroy the enemy Commandant within 3 turns.",
    sideToMove = "Blue",
    turnLimitRounds = 3,
    scenarioRedPolicy = {
        runtime = "scenarioRedRuntime",
        policy = "scenarioRedPolicy",
        policyVersion = "scenario_red_policy.v2",
        policyHash = "red_policy_v2_plan2_static_2026_05_03",
        seed = 505,
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_interceptor"
        },
        requiredCells = {
            { row = 6, col = 5 },
            { row = 7, col = 6 },
            { row = 5, col = 6 },
            { row = 2, col = 6 }
        }
    },
    startSnapshot = snapshotBuilder.build({
        currentTurn = 1,
        currentPlayer = 1,
        currentTurnActions = 0,
        maxActionsPerTurn = 2,
        logicRngSeed = 13035,
        factionAssignments = {
            [1] = "local_player_1",
            [2] = "local_ai_1"
        },
        units = {
            {
                id = "blue_finisher",
                name = "Artillery",
                player = 1,
                row = 8,
                col = 6,
                currentHp = 4,
                startingHp = 5
            },
            {
                id = "blue_interceptor",
                name = "Earthstalker",
                player = 1,
                row = 7,
                col = 5,
                currentHp = 3,
                startingHp = 3
            },
            {
                id = "blue_decoy",
                name = "Bastion",
                player = 1,
                row = 6,
                col = 7,
                currentHp = 3,
                startingHp = 6
            },
            {
                id = "red_commandant",
                name = "Commandant",
                player = 2,
                row = 2,
                col = 6,
                currentHp = 2,
                startingHp = 12
            },
            {
                id = "red_hunter",
                name = "Earthstalker",
                player = 2,
                row = 6,
                col = 4,
                currentHp = 3,
                startingHp = 3
            }
        }
    })
}
