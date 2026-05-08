local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P003",
    name = "Scenario P003",
    status = "PROMOTED",
    promotion = {
        state = "promoted",
        approved = true,
        source = "manual_playtest_capture_discipline_4"
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
        seed = 303,
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_opener",
            "blue_screen"
        },
        requiredCells = {
            { row = 6, col = 4 },
            { row = 4, col = 7 },
            { row = 4, col = 4 },
            { row = 3, col = 4 }
        }
    },
    startSnapshot = snapshotBuilder.build({
        currentTurn = 1,
        currentPlayer = 1,
        currentTurnActions = 0,
        maxActionsPerTurn = 2,
        logicRngSeed = 13027,
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
                col = 4,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "blue_opener",
                name = "Cloudstriker",
                player = 1,
                row = 7,
                col = 7,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "blue_screen",
                name = "Earthstalker",
                player = 1,
                row = 5,
                col = 6,
                currentHp = 3,
                startingHp = 3
            },
            {
                id = "red_commandant",
                name = "Commandant",
                player = 2,
                row = 2,
                col = 4,
                currentHp = 4,
                startingHp = 12
            },
            {
                id = "neutral_gate",
                name = "Rock",
                player = 0,
                row = 4,
                col = 4,
                currentHp = 2,
                startingHp = 5
            },
            {
                id = "neutral_guard",
                name = "Rock",
                player = 0,
                row = 3,
                col = 4,
                currentHp = 3,
                startingHp = 5
            },
            {
                id = "red_battery",
                name = "Artillery",
                player = 2,
                row = 6,
                col = 1,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "red_lure",
                name = "Wingstalker",
                player = 2,
                row = 5,
                col = 7,
                currentHp = 2,
                startingHp = 3
            }
        }
    })
}
