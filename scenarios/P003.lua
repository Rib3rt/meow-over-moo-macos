local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P003",
    name = "Scenario P003",
    status = "PROMOTED",
    promotion = {
        state = "promoted",
        approved = true,
        source = "manual_playtest_breach_doubt_candidate"
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
        seed = 303,
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_breaker",
            "blue_decoy"
        },
        requiredCells = {
            { row = 3, col = 4 },
            { row = 3, col = 5 },
            { row = 5, col = 5 }
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
                id = "blue_breaker",
                name = "Earthstalker",
                player = 1,
                row = 5,
                col = 4,
                currentHp = 2,
                startingHp = 3
            },
            {
                id = "blue_finisher",
                name = "Crusher",
                player = 1,
                row = 7,
                col = 5,
                currentHp = 4,
                startingHp = 4
            },
            {
                id = "blue_decoy",
                name = "Bastion",
                player = 1,
                row = 5,
                col = 7,
                currentHp = 6,
                startingHp = 6
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
                id = "red_contact_blocker",
                name = "Bastion",
                player = 2,
                row = 3,
                col = 5,
                currentHp = 2,
                startingHp = 6
            },
            {
                id = "red_breaker_hunter",
                name = "Earthstalker",
                player = 2,
                row = 5,
                col = 2,
                currentHp = 3,
                startingHp = 3
            }
        }
    })
}
