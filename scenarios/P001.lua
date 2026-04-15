local snapshotBuilder = require("puzzle_snapshot_builder")

return {
    id = "P001",
    name = "Scenario P001",
    status = "READY",
    objectiveType = "destroy_commandant",
    objectiveMessage = "Blue to move. Destroy the enemy Commandant within 3 turns.",
    objectiveText = "Blue to move. Destroy the enemy Commandant within 3 turns.",
    sideToMove = "Blue",
    turnLimitRounds = 3,
    startSnapshot = snapshotBuilder.build({
        currentTurn = 1,
        currentPlayer = 1,
        currentTurnActions = 0,
        factionAssignments = {
            [1] = "local_player_1",
            [2] = "local_ai_1"
        },
        units = {
            { name = "Artillery", player = 1, row = 6, col = 2, currentHp = 3 },
            { name = "Wingstalker", player = 1, row = 6, col = 3, currentHp = 2 },
            { name = "Crusher", player = 1, row = 6, col = 5, currentHp = 4 },
            { name = "Cloudstriker", player = 1, row = 6, col = 6, currentHp = 4 },

            { name = "Commandant", player = 2, row = 2, col = 2, currentHp = 6 },
            { name = "Bastion", player = 2, row = 2, col = 4, currentHp = 6 },
            { name = "Wingstalker", player = 2, row = 3, col = 4, currentHp = 3 },
            { name = "Artillery", player = 2, row = 3, col = 5, currentHp = 5 },
            { name = "Crusher", player = 2, row = 5, col = 4, currentHp = 4 }
        }
    })
}
