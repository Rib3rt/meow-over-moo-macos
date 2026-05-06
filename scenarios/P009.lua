local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P009",
    name = "Scenario P009",
    status = "PROMOTED",
    promotion = {
        state = "promoted",
        approved = true,
        source = "manual_playtest_capture_ladder"
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
        seed = 909,
        criticalBlueUnitIds = {
            "blue_crusher",
            "blue_wing",
            "blue_stalker",
            "blue_side_battery"
        },
        requiredCells = {
            { row = 6, col = 3 },
            { row = 3, col = 5 },
            { row = 3, col = 1 },
            { row = 4, col = 6 },
            { row = 3, col = 7 },
            { row = 4, col = 3 },
            { row = 3, col = 3 },
            { row = 2, col = 3 }
        }
    },
    startSnapshot = snapshotBuilder.build({
        currentTurn = 1,
        currentPlayer = 1,
        currentTurnActions = 0,
        maxActionsPerTurn = 2,
        logicRngSeed = 13049,
        factionAssignments = {
            [1] = "local_player_1",
            [2] = "local_ai_1"
        },
        units = {
            {
                id = "blue_crusher",
                name = "Crusher",
                player = 1,
                row = 7,
                col = 3,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "blue_stalker",
                name = "Earthstalker",
                player = 1,
                row = 4,
                col = 5,
                currentHp = 3,
                startingHp = 3
            },
            {
                id = "blue_wing",
                name = "Wingstalker",
                player = 1,
                row = 6,
                col = 7,
                currentHp = 3,
                startingHp = 3
            },
            {
                id = "blue_side_battery",
                name = "Artillery",
                player = 1,
                row = 3,
                col = 1,
                currentHp = 5,
                startingHp = 5
            },
            {
                id = "red_commandant",
                name = "Commandant",
                player = 2,
                row = 1,
                col = 3,
                currentHp = 4,
                startingHp = 12
            },
            {
                id = "red_step1",
                name = "Earthstalker",
                player = 2,
                row = 6,
                col = 3,
                currentHp = 3,
                startingHp = 3
            },
            {
                id = "red_step2",
                name = "Crusher",
                player = 2,
                row = 3,
                col = 3,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "red_cloud",
                name = "Cloudstriker",
                player = 2,
                row = 6,
                col = 6,
                currentHp = 2,
                startingHp = 4
            },
            {
                id = "red_hunter",
                name = "Crusher",
                player = 2,
                row = 4,
                col = 6,
                currentHp = 4,
                startingHp = 4
            }
        }
    })
}
