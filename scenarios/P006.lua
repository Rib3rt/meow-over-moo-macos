local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P006",
    name = "Scenario P006",
    status = "PROMOTED",
    promotion = {
        state = "promoted",
        approved = true,
        source = "manual_playtest_bastion_siege_walk"
    },
    objectiveType = "destroy_commandant",
    objectiveMessage = "Blue to move. Destroy the enemy Commandant within 4 turns.",
    objectiveText = "Blue to move. Destroy the enemy Commandant within 4 turns.",
    sideToMove = "Blue",
    turnLimitRounds = 4,
    scenarioRedPolicy = {
        runtime = "scenarioRedRuntime",
        policy = "scenarioRedPolicy",
        policyVersion = "scenario_red_policy.v2",
        policyHash = "red_policy_v2_plan2_static_2026_05_03",
        seed = 606,
        criticalBlueUnitIds = {
            "blue_finisher"
        },
        requiredCells = {
            { row = 5, col = 8 },
            { row = 2, col = 8 },
            { row = 2, col = 5 },
            { row = 2, col = 2 },
            { row = 8, col = 5 },
            { row = 6, col = 5 }
        }
    },
    startSnapshot = snapshotBuilder.build({
        currentTurn = 1,
        currentPlayer = 1,
        currentTurnActions = 0,
        maxActionsPerTurn = 2,
        logicRngSeed = 13046,
        factionAssignments = {
            [1] = "local_player_1",
            [2] = "local_ai_1"
        },
        units = {
            {
                id = "blue_finisher",
                name = "Bastion",
                player = 1,
                row = 8,
                col = 8,
                currentHp = 4,
                startingHp = 6
            },
            {
                id = "blue_decoy",
                name = "Earthstalker",
                player = 1,
                row = 8,
                col = 3,
                currentHp = 1,
                startingHp = 3
            },
            {
                id = "blue_reserve",
                name = "Crusher",
                player = 1,
                row = 8,
                col = 1,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "red_commandant",
                name = "Commandant",
                player = 2,
                row = 1,
                col = 2,
                currentHp = 1,
                startingHp = 12
            },
            {
                id = "red_hunter",
                name = "Crusher",
                player = 2,
                row = 5,
                col = 7,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "red_battery",
                name = "Artillery",
                player = 2,
                row = 6,
                col = 1,
                currentHp = 5,
                startingHp = 5
            }
        }
    })
}
