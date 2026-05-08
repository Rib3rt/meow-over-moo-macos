local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P005",
    name = "Scenario P005",
    status = "PROMOTED",
    promotion = {
        state = "promoted",
        approved = true,
        source = "manual_playtest_crossed_march_4"
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
        seed = 505,
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_opener",
            "blue_cover"
        },
        requiredCells = {
            { row = 8, col = 6 },
            { row = 8, col = 5 },
            { row = 6, col = 5 },
            { row = 5, col = 5 }
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
                name = "Crusher",
                player = 1,
                row = 8,
                col = 8,
                currentHp = 2,
                startingHp = 4
            },
            {
                id = "blue_opener",
                name = "Cloudstriker",
                player = 1,
                row = 3,
                col = 6,
                currentHp = 2,
                startingHp = 4
            },
            {
                id = "blue_cover",
                name = "Artillery",
                player = 1,
                row = 8,
                col = 2,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "red_commandant",
                name = "Commandant",
                player = 2,
                row = 4,
                col = 5,
                currentHp = 4,
                startingHp = 12
            },
            {
                id = "red_gate",
                name = "Earthstalker",
                player = 2,
                row = 6,
                col = 6,
                currentHp = 2,
                startingHp = 3
            },
            {
                id = "red_battery",
                name = "Artillery",
                player = 2,
                row = 8,
                col = 5,
                currentHp = 2,
                startingHp = 4
            },
            {
                id = "neutral_d8_lock",
                name = "Rock",
                player = 0,
                row = 8,
                col = 4,
                currentHp = 2,
                startingHp = 2
            },
            {
                id = "neutral_d4_screen",
                name = "Rock",
                player = 0,
                row = 4,
                col = 4,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "red_chaser",
                name = "Wingstalker",
                player = 2,
                row = 2,
                col = 8,
                currentHp = 3,
                startingHp = 3
            }
        }
    })
}
