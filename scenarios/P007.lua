local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P007",
    name = "Scenario P007",
    status = "PROMOTED",
    promotion = {
        state = "promoted",
        approved = true,
        source = "manual_playtest_shutter_shot"
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
        seed = 707,
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_opener"
        },
        requiredCells = {
            { row = 4, col = 5 },
            { row = 1, col = 5 },
            { row = 1, col = 4 },
            { row = 7, col = 1 }
        }
    },
    startSnapshot = snapshotBuilder.build({
        currentTurn = 1,
        currentPlayer = 1,
        currentTurnActions = 0,
        maxActionsPerTurn = 2,
        logicRngSeed = 13047,
        factionAssignments = {
            [1] = "local_player_1",
            [2] = "local_ai_1"
        },
        units = {
            {
                id = "blue_finisher",
                name = "Cloudstriker",
                player = 1,
                row = 1,
                col = 8,
                currentHp = 2,
                startingHp = 4
            },
            {
                id = "blue_opener",
                name = "Artillery",
                player = 1,
                row = 4,
                col = 4,
                currentHp = 1,
                startingHp = 5
            },
            {
                id = "blue_interposer",
                name = "Wingstalker",
                player = 1,
                row = 7,
                col = 5,
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
                currentHp = 3,
                startingHp = 12
            },
            {
                id = "red_hunter",
                name = "Crusher",
                player = 2,
                row = 4,
                col = 6,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "red_battery",
                name = "Artillery",
                player = 2,
                row = 5,
                col = 1,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "red_false_lure",
                name = "Cloudstriker",
                player = 2,
                row = 7,
                col = 2,
                currentHp = 2,
                startingHp = 4
            },
            {
                id = "red_lure_screen",
                name = "Rock",
                player = 0,
                row = 7,
                col = 4,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "neutral_screen",
                name = "Rock",
                player = 0,
                row = 1,
                col = 4,
                currentHp = 4,
                startingHp = 5
            }
        }
    })
}
