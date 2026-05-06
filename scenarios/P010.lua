local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P010",
    name = "Scenario P010",
    status = "PROMOTED",
    promotion = {
        state = "promoted",
        approved = true,
        source = "manual_playtest_gate_march"
    },
    objectiveType = "destroy_commandant",
    objectiveMessage = "Blue to move. Destroy the enemy Commandant within 5 turns.",
    objectiveText = "Blue to move. Destroy the enemy Commandant within 5 turns.",
    sideToMove = "Blue",
    turnLimitRounds = 5,
    scenarioRedPolicy = {
        runtime = "scenarioRedRuntime",
        policy = "scenarioRedPolicy",
        policyVersion = "scenario_red_policy.v2",
        policyHash = "red_policy_v2_plan2_static_2026_05_03",
        seed = 1010,
        criticalBlueUnitIds = {
            "blue_breaker",
            "blue_finisher",
            "blue_decoy",
            "blue_screen"
        },
        requiredCells = {
            { row = 1, col = 4 },
            { row = 3, col = 5 },
            { row = 1, col = 5 },
            { row = 4, col = 4 },
            { row = 7, col = 6 },
            { row = 8, col = 6 }
        }
    },
    startSnapshot = snapshotBuilder.build({
        currentTurn = 1,
        currentPlayer = 1,
        currentTurnActions = 0,
        maxActionsPerTurn = 2,
        logicRngSeed = 13050,
        factionAssignments = {
            [1] = "local_player_1",
            [2] = "local_ai_1"
        },
        units = {
            {
                id = "blue_breaker",
                name = "Artillery",
                player = 1,
                row = 8,
                col = 4,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "blue_finisher",
                name = "Cloudstriker",
                player = 1,
                row = 1,
                col = 8,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "blue_decoy",
                name = "Bastion",
                player = 1,
                row = 4,
                col = 6,
                currentHp = 2,
                startingHp = 6
            },
            {
                id = "blue_screen",
                name = "Wingstalker",
                player = 1,
                row = 8,
                col = 5,
                currentHp = 3,
                startingHp = 3
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
                id = "neutral_gate",
                name = "Rock",
                player = 0,
                row = 1,
                col = 4,
                currentHp = 2,
                startingHp = 5
            },
            {
                id = "neutral_screen",
                name = "Rock",
                player = 0,
                row = 3,
                col = 5,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "red_hunter",
                name = "Crusher",
                player = 2,
                row = 7,
                col = 5,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "red_sniper",
                name = "Cloudstriker",
                player = 2,
                row = 4,
                col = 5,
                currentHp = 3,
                startingHp = 4
            }
        }
    })
}
