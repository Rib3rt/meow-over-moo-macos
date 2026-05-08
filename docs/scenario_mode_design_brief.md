# Scenario Mode Design Brief

This is the compact brief for an agent designing Scenario Mode puzzles.

Scenario Mode is not the full game. Ignore supply, Blue Commandant setup, deployment, and standard AI. A scenario is a curated tactical puzzle where Blue starts with a fixed board and must destroy the Red Commandant inside the advertised turn limit.

## Scenario Rules

- Board size is 8x8.
- Blue is player `1`, Red is player `2`, neutral Rock is player `0`.
- Blue always starts.
- Blue gets exactly 2 actions per Blue turn.
- Red gets exactly 2 actions per Red turn through the deterministic Scenario Red Policy.
- A unit can move once and attack once in the same turn, in either order if legal.
- `Commandant`, `Rock`, and `Healer` do not act in Scenario Mode.
- The win condition is destroying the Red Commandant.
- The advertised turn limit is binding. If a 3-turn scenario can be solved in 1 or 2 Blue turns, it fails.
- Standard AI must not be used for scenario runtime, proof, fallback, or design approval.
- Scenario Red Policy must be deterministic and versioned.
- When a melee unit destroys a target, it occupies the destroyed target's cell.
- Ranged units do not move into the destroyed target's cell.

## Movement And Attacks

- Movement is orthogonal only.
- Ground units cannot move through occupied cells.
- Flying units can move over occupied cells, but cannot end on an occupied cell.
- Attacks use Manhattan distance.
- Melee attackers can attack adjacent cells only.
- `Cloudstriker` and `Artillery` cannot attack adjacent cells. Their minimum range is 2.
- `Cloudstriker` requires clear orthogonal line of sight and cannot shoot through units or Rocks.
- `Artillery` attacks orthogonally and can shoot through Rocks and units.
- Targets can be enemy units, the Red Commandant, or neutral Rocks.

## Unit Reference

| Unit | HP | Move | Range | Damage | Flying | Scenario notes |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| Commandant | 12 | 0 | 1 | 1 | No | Red objective. Does not act as a normal unit in Scenario Mode. |
| Wingstalker | 3 | 3 | 1 | 1 | Yes | +1 damage against flying units. |
| Crusher | 4 | 2 | 1 | 3 | No | +1 damage against Commandant, so 4 vs Commandant. Melee capture on kill. |
| Bastion | 6 | 2 | 1 | 1 | No | Takes -1 damage from non-ranged melee attacks. Melee capture on kill. |
| Cloudstriker | 4 | 3 | 3 | 2 | Yes | Range 2-3. Needs line of sight. +1 damage vs Rock and Commandant. |
| Earthstalker | 3 | 2 | 1 | 2 | No | +2 damage vs non-flying, non-Rock, non-Commandant units. Melee capture on kill. |
| Artillery | 5 | 1 | 3 | 1 | No | Range 2-3 orthogonal. Shoots through blockers. +1 damage vs Rock and Commandant. |
| Rock | 5 | 0 | 0 | 0 | No | Neutral obstacle. Can be damaged/destroyed. Does not act. |

## What A Scenario Must Be

A scenario is a tactical interaction chain, not just a solvable board.

Every accepted scenario must have:

- A clear turn target from 3 to 10 Blue turns.
- A unique computable finisher for the winning Commandant kill.
- At least one active Red unit besides the Commandant, unless the user explicitly approves a special exception.
- Red material that matters: it must block, hunt, chase, threaten, force timing, or punish a false path.
- Separate Blue roles: finisher, support, lure, blocker-clearer, path-opener, or tempo piece.
- A first Blue action that is not an obvious free payoff.
- A plausible false path that looks productive, then fails for a computed reason.
- Action-consequence proof for every key Blue action.
- A binding duration proof: the puzzle must not be solvable in fewer Blue turns than advertised.
- Runtime proof with Scenario Red Policy, not Red-pass only.
- Enough ambiguity that the player has to discover why a unit is needed.

Good scenarios make the player ask:

- Which unit is the real finisher?
- Which obstacle or enemy must be handled first?
- Which action looks useful but loses tempo?
- What does Red do if I choose the wrong plan?
- Why does the exact order matter?

## What A Scenario Must Not Be

Reject the scenario if any of these are true:

- It has no active Red unit besides the Commandant.
- Red units are decorative and can be removed without changing the solution contract.
- It is just a path-clear puzzle against Rocks.
- The first move is forced and obviously correct.
- The first move is an immediate obvious Commandant hit unless it is a proven false path.
- The false path is only "do nothing" or an obviously bad move.
- A Rock obstacle solves itself.
- A Red unit wanders because it has no meaningful target.
- The board can be solved earlier than the stated turn limit.
- Multiple Blue units can independently finish the Commandant.
- The same unit attacks from the same cell over and over as the main puzzle texture.
- It is a translated or lightly reskinned copy of an accepted scenario.
- It depends on standard AI behavior.
- It only passes because Red does nothing.
- It needs a hidden hardcoded Red move to work.

## Lessons From Early Public Scenarios

Use these as quality examples, not templates to clone.

- P002: uses Rocks, Red pressure, and multiple tempting lanes. The geometry creates doubt about what must be opened and when.
- P003: three Blue ground units create role ambiguity. The false heavy advance looks natural but loses the required breaker.
- P004: the lure matters. Red Bastion movement is part of the contract; the Rock clear alone is insufficient.

The shared lesson is not "use a Rock near the Commandant." The lesson is that every piece must earn its place through consequence.

## Minimum Approval Checklist

Before presenting a candidate:

- Count active Red units. There must be at least one non-Commandant Red unit with a real purpose.
- Replay the intended solution under Scenario Red Policy.
- Replay at least one false path and explain why it fails.
- Prove or tightly bound that the advertised turn count cannot be compressed.
- Check that the first action is not an obvious payoff.
- Check that exactly one Blue unit is the final finisher.
- Check that each support action changes legality, survivability, tempo, Red movement, or final damage.
- Compare the geometry and interaction pattern against the existing public scenarios to avoid cloning.
- If a qualitative claim cannot be computed or replayed, do not use it to approve the scenario.

## Import JSON Format

The game currently loads public Scenario Mode levels as Lua payloads under `scenarios/P###.lua`. Use this JSON shape as the canonical exchange/import format. An importer should convert it into the same fields used by the Lua scenario payload: `id`, `name`, `status`, `promotion`, `objectiveType`, `objectiveMessage`, `objectiveText`, `sideToMove`, `turnLimitRounds`, `scenarioRedPolicy`, and `startSnapshot`.

Top-level required fields:

- `id`: stable scenario id, for example `"P005"`.
- `name`: public display name. Use `"Scenario P005"`; do not add a title.
- `status`: use `"PROMOTED"` only for a candidate intentionally exposed in the public scenario list.
- `promotion`: metadata object. For manual work use `state: "promoted"`, `approved: true`, and a short `source`.
- `objectiveType`: use `"destroy_commandant"`.
- `objectiveMessage` and `objectiveText`: same visible objective text.
- `sideToMove`: use `"Blue"`.
- `turnLimitRounds`: integer from 3 to 10.
- `scenarioRedPolicy`: deterministic Red runtime config.
- `startSnapshot`: fixed initial board state.

Minimal JSON example:

```json
{
  "id": "P005",
  "name": "Scenario P005",
  "status": "PROMOTED",
  "promotion": {
    "state": "promoted",
    "approved": true,
    "source": "manual_playtest_candidate"
  },
  "objectiveType": "destroy_commandant",
  "objectiveMessage": "Blue to move. Destroy the enemy Commandant within 3 turns.",
  "objectiveText": "Blue to move. Destroy the enemy Commandant within 3 turns.",
  "sideToMove": "Blue",
  "turnLimitRounds": 3,
  "scenarioRedPolicy": {
    "runtime": "scenarioRedRuntime",
    "policy": "scenarioRedPolicy",
    "policyVersion": "scenario_red_policy.v2",
    "policyHash": "red_policy_v2_plan2_static_2026_05_03",
    "seed": 505,
    "criticalBlueUnitIds": [
      "blue_finisher",
      "blue_support"
    ],
    "requiredCells": [
      { "row": 4, "col": 5 },
      { "row": 3, "col": 5 }
    ]
  },
  "startSnapshot": {
    "version": 4,
    "currentPhase": "turn",
    "currentTurnPhase": "actions",
    "currentTurn": 1,
    "currentPlayer": 1,
    "turnOrder": [1, 2],
    "factionAssignments": {
      "1": "local_player_1",
      "2": "local_ai_1"
    },
    "winner": null,
    "maxActionsPerTurn": 2,
    "currentTurnActions": 0,
    "hasDeployedThisTurn": true,
    "commandHubPositions": {
      "2": { "row": 2, "col": 5 }
    },
    "tempCommandHubPosition": {},
    "commandHubPlacementReady": true,
    "initialDeployment": {
      "requiredDeployments": 0,
      "completedDeployments": 0,
      "selectedUnitIndex": null,
      "availableCells": []
    },
    "turnsWithoutDamage": 0,
    "turnHadInteraction": false,
    "drawGame": false,
    "noMoreUnitsGameOver": false,
    "logicRngSeed": 13005,
    "logicRngState": 13005,
    "neutralBuildings": {},
    "neutralBuildingsPlaced": 0,
    "targetRows": [3, 4, 5, 6],
    "usedRows": {},
    "actionsPhaseSupplySelection": null,
    "playerSupplies": {
      "1": [],
      "2": []
    },
    "gridSetupComplete": {
      "1": true,
      "2": true
    },
    "boardUnits": [
      {
        "scenarioUnitId": "blue_finisher",
        "name": "Crusher",
        "player": 1,
        "row": 7,
        "col": 5,
        "currentHp": 4,
        "startingHp": 4,
        "hasActed": false,
        "turnActions": {}
      },
      {
        "scenarioUnitId": "red_commandant",
        "name": "Commandant",
        "player": 2,
        "row": 2,
        "col": 5,
        "currentHp": 4,
        "startingHp": 12,
        "hasActed": false,
        "turnActions": {}
      },
      {
        "scenarioUnitId": "red_pressure",
        "name": "Bastion",
        "player": 2,
        "row": 3,
        "col": 5,
        "currentHp": 3,
        "startingHp": 6,
        "hasActed": false,
        "turnActions": {}
      },
      {
        "scenarioUnitId": "neutral_lock",
        "name": "Rock",
        "player": 0,
        "row": 4,
        "col": 5,
        "currentHp": 2,
        "startingHp": 5,
        "hasActed": false,
        "turnActions": {}
      }
    ],
    "integritySignature": {
      "boardUnitTotal": 4,
      "boardByPlayer": {
        "0": 1,
        "1": 1,
        "2": 2
      },
      "supplyByPlayer": {
        "1": 0,
        "2": 0
      },
      "commandants": {
        "1": 0,
        "2": 1
      }
    }
  }
}
```

### JSON Field Rules

- Coordinates are 1-based: `row` and `col` must be between 1 and 8.
- No two live units may start on the same cell.
- Every `boardUnits[]` entry must have a stable `scenarioUnitId`.
- Use only these unit names: `Commandant`, `Wingstalker`, `Crusher`, `Bastion`, `Cloudstriker`, `Earthstalker`, `Artillery`, `Rock`.
- `player` must be `1` for Blue, `2` for Red, and `0` for Rock.
- There must be exactly one Red `Commandant`.
- There must be no Blue `Commandant`.
- There must be at least one Blue unit.
- There must be at least one active non-Commandant Red unit unless explicitly approved as an exception.
- `currentHp` may be lower than `startingHp` to create tactical damage states, but must be at least 1.
- `startingHp` should match the unit reference table unless there is a deliberate reason.
- `commandHubPositions["2"]` must match the Red Commandant cell.
- `maxActionsPerTurn` must be `2`.
- `currentPlayer` must be `1`.
- `currentTurn` must be `1`.
- `currentTurnActions` must be `0`.
- `playerSupplies` must be empty arrays for both players.
- `initialDeployment.requiredDeployments` and `completedDeployments` must be `0`.
- `scenarioRedPolicy.criticalBlueUnitIds` should include the Blue units Red must understand as tactically important.
- `scenarioRedPolicy.requiredCells` should include cells that matter to the intended Red response, path, block, lure, or finisher route.
- `integritySignature` should match `boardUnits`; an importer may recompute it instead of trusting the JSON.

### Compact Authoring Format

For design discussion before import, an agent may use this smaller JSON and let tooling build `startSnapshot`:

```json
{
  "id": "P005",
  "turnLimitRounds": 3,
  "units": [
    { "id": "blue_finisher", "name": "Crusher", "player": 1, "row": 7, "col": 5, "currentHp": 4 },
    { "id": "blue_support", "name": "Artillery", "player": 1, "row": 4, "col": 2, "currentHp": 5 },
    { "id": "red_commandant", "name": "Commandant", "player": 2, "row": 2, "col": 5, "currentHp": 4 },
    { "id": "red_pressure", "name": "Bastion", "player": 2, "row": 4, "col": 5, "currentHp": 3 },
    { "id": "neutral_lock", "name": "Rock", "player": 0, "row": 3, "col": 5, "currentHp": 2 }
  ],
  "scenarioRedPolicy": {
    "seed": 505,
    "criticalBlueUnitIds": ["blue_finisher", "blue_support"],
    "requiredCells": [
      { "row": 4, "col": 5 },
      { "row": 3, "col": 5 }
    ]
  }
}
```

The compact format is not the final runtime payload. It is acceptable only if the importer expands it into the full format above and then runs the approval checklist.

## Approved Puzzle Examples

These are compact authoring JSON versions of the approved puzzles. They are examples for structure and interaction quality, not templates to copy.

### P002 Example

Why it matters: rocks create route ambiguity, Red has multiple active units, and the board asks the player to decide which lane/lock actually matters.

```json
{
  "id": "P002",
  "turnLimitRounds": 3,
  "units": [
    { "id": "blue_a_support", "name": "Artillery", "player": 1, "row": 3, "col": 3, "currentHp": 4 },
    { "id": "blue_finisher", "name": "Cloudstriker", "player": 1, "row": 6, "col": 7, "currentHp": 4 },
    { "id": "red_commandant", "name": "Commandant", "player": 2, "row": 2, "col": 4, "currentHp": 3 },
    { "id": "red_support_threat", "name": "Earthstalker", "player": 2, "row": 5, "col": 3, "currentHp": 1 },
    { "id": "neutral_rock", "name": "Rock", "player": 0, "row": 2, "col": 5, "currentHp": 2 },
    { "id": "neutral_shortcut_rock", "name": "Rock", "player": 0, "row": 3, "col": 4, "currentHp": 5 },
    { "id": "editor_2_crusher_6_6_7", "name": "Crusher", "player": 2, "row": 6, "col": 6, "currentHp": 2 },
    { "id": "editor_2_crusher_5_4_8", "name": "Crusher", "player": 2, "row": 5, "col": 4, "currentHp": 2 }
  ],
  "scenarioRedPolicy": {
    "seed": 1781346111,
    "criticalBlueUnitIds": ["blue_finisher", "blue_a_support"],
    "requiredCells": [
      { "row": 2, "col": 3 },
      { "row": 2, "col": 7 },
      { "row": 3, "col": 3 },
      { "row": 3, "col": 7 },
      { "row": 4, "col": 4 }
    ]
  }
}
```

### P003 Example

Why it matters: three Blue ground units create role ambiguity. The tempting heavy advance looks productive but loses the required breaker.

```json
{
  "id": "P003",
  "turnLimitRounds": 3,
  "units": [
    { "id": "blue_breaker", "name": "Earthstalker", "player": 1, "row": 5, "col": 4, "currentHp": 2 },
    { "id": "blue_finisher", "name": "Crusher", "player": 1, "row": 7, "col": 5, "currentHp": 4 },
    { "id": "blue_decoy", "name": "Bastion", "player": 1, "row": 5, "col": 7, "currentHp": 6 },
    { "id": "red_commandant", "name": "Commandant", "player": 2, "row": 2, "col": 5, "currentHp": 4 },
    { "id": "red_contact_blocker", "name": "Bastion", "player": 2, "row": 3, "col": 5, "currentHp": 2 },
    { "id": "red_breaker_hunter", "name": "Earthstalker", "player": 2, "row": 5, "col": 2, "currentHp": 3 }
  ],
  "scenarioRedPolicy": {
    "seed": 303,
    "criticalBlueUnitIds": ["blue_finisher", "blue_breaker", "blue_decoy"],
    "requiredCells": [
      { "row": 3, "col": 4 },
      { "row": 3, "col": 5 },
      { "row": 5, "col": 5 }
    ]
  }
}
```

### P004 Example

Why it matters: the lure is real. Clearing the Rock alone is not enough; Blue must make Red move the Bastion out of the finisher cell.

```json
{
  "id": "P004",
  "turnLimitRounds": 3,
  "units": [
    { "id": "blue_finisher", "name": "Cloudstriker", "player": 1, "row": 7, "col": 5, "currentHp": 4 },
    { "id": "blue_artillery", "name": "Artillery", "player": 1, "row": 4, "col": 2, "currentHp": 5 },
    { "id": "blue_lure", "name": "Earthstalker", "player": 1, "row": 6, "col": 4, "currentHp": 1 },
    { "id": "red_commandant", "name": "Commandant", "player": 2, "row": 1, "col": 5, "currentHp": 3 },
    { "id": "neutral_line_lock", "name": "Rock", "player": 0, "row": 3, "col": 5, "currentHp": 2 },
    { "id": "red_cell_guard", "name": "Bastion", "player": 2, "row": 4, "col": 5, "currentHp": 3 },
    { "id": "neutral_anti_shortcut", "name": "Rock", "player": 0, "row": 6, "col": 5, "currentHp": 5 }
  ],
  "scenarioRedPolicy": {
    "seed": 404,
    "criticalBlueUnitIds": ["blue_finisher"],
    "requiredCells": [
      { "row": 3, "col": 2 },
      { "row": 5, "col": 4 },
      { "row": 4, "col": 5 },
      { "row": 3, "col": 5 },
      { "row": 6, "col": 5 }
    ]
  }
}
```
