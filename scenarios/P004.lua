local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P004",
    name = "Scenario P004",
    status = "PROMOTED",
    promotion = {
        state = "promoted",
        approved = true,
        source = "manual_playtest_790_promoted"
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
        seed = 404,
        criticalBlueUnitIds = {
            "blue_finisher"
        },
        requiredCells = {
            { row = 3, col = 2 },
            { row = 5, col = 4 },
            { row = 4, col = 5 },
            { row = 3, col = 5 },
            { row = 6, col = 5 }
        }
    },
    startSnapshot = snapshotBuilder.build({
        currentTurn = 1,
        currentPlayer = 1,
        currentTurnActions = 0,
        maxActionsPerTurn = 2,
        logicRngSeed = 13011,
        factionAssignments = {
            [1] = "local_player_1",
            [2] = "local_ai_1"
        },
        units = {
            {
                id = "blue_finisher",
                name = "Cloudstriker",
                player = 1,
                row = 7,
                col = 5,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "blue_artillery",
                name = "Artillery",
                player = 1,
                row = 4,
                col = 2,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "blue_lure",
                name = "Earthstalker",
                player = 1,
                row = 6,
                col = 4,
                currentHp = 1,
                startingHp = 3
            },
            {
                id = "red_commandant",
                name = "Commandant",
                player = 2,
                row = 1,
                col = 5,
                currentHp = 3,
                startingHp = 12
            },
            {
                id = "neutral_line_lock",
                name = "Rock",
                player = 0,
                row = 3,
                col = 5,
                currentHp = 2,
                startingHp = 5
            },
            {
                id = "red_cell_guard",
                name = "Bastion",
                player = 2,
                row = 4,
                col = 5,
                currentHp = 3,
                startingHp = 6
            },
            {
                id = "neutral_anti_shortcut",
                name = "Rock",
                player = 0,
                row = 6,
                col = 5,
                currentHp = 5,
                startingHp = 5
            }
        }
    })
}
