local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P011",
    name = "Scenario P011",
    status = "PROMOTED",
    promotion = {
        state = "promoted",
        approved = true,
        source = "manual_playtest_jagged_crusher_breach_6"
    },
    objectiveType = "destroy_commandant",
    objectiveMessage = "Blue to move. Destroy the enemy Commandant within 6 turns.",
    objectiveText = "Blue to move. Destroy the enemy Commandant within 6 turns.",
    sideToMove = "Blue",
    turnLimitRounds = 6,
    scenarioRedPolicy = {
        runtime = "scenarioRedRuntime",
        policy = "scenarioRedPolicy",
        policyVersion = "scenario_red_policy.v2",
        policyHash = "red_policy_v2_plan2_static_2026_05_03",
        seed = 1111,
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_artillery",
            "blue_cloud"
        },
        requiredCells = {
            { row = 6, col = 2 },
            { row = 6, col = 4 },
            { row = 4, col = 4 },
            { row = 4, col = 6 },
            { row = 3, col = 6 }
        }
    },
    startSnapshot = snapshotBuilder.build({
        currentTurn = 1,
        currentPlayer = 1,
        currentTurnActions = 0,
        maxActionsPerTurn = 2,
        logicRngSeed = 13071,
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
                col = 2,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "blue_artillery",
                name = "Artillery",
                player = 1,
                row = 4,
                col = 1,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "blue_cloud",
                name = "Cloudstriker",
                player = 1,
                row = 4,
                col = 8,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "red_commandant",
                name = "Commandant",
                player = 2,
                row = 2,
                col = 5,
                currentHp = 4,
                startingHp = 12
            },
            {
                id = "neutral_step1",
                name = "Rock",
                player = 0,
                row = 6,
                col = 2,
                currentHp = 3,
                startingHp = 5
            },
            {
                id = "neutral_step2",
                name = "Rock",
                player = 0,
                row = 6,
                col = 4,
                currentHp = 3,
                startingHp = 5
            },
            {
                id = "neutral_mid_lock",
                name = "Rock",
                player = 0,
                row = 4,
                col = 4,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "neutral_final_lock",
                name = "Rock",
                player = 0,
                row = 4,
                col = 6,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "neutral_h2_anchor",
                name = "Rock",
                player = 0,
                row = 2,
                col = 8,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "neutral_e3_anchor",
                name = "Rock",
                player = 0,
                row = 3,
                col = 5,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "red_battery",
                name = "Artillery",
                player = 2,
                row = 6,
                col = 8,
                currentHp = 5,
                startingHp = 5
            }
        }
    })
}
