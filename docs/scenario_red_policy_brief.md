# Scenario Red Policy Brief

This document explains how deterministic Red chooses actions in Scenario Mode.

The implementation is `scenarioRedPolicy.lua`, version `scenario_red_policy.v2`, hash `red_policy_v2_plan2_static_2026_05_03`.

Scenario Red Policy is not the standard AI. It does not read the scenario solution, false-line id, scenario id, generator proof, standard gameplay AI, or hidden designer instructions. It scores legal actions from the current scenario state plus `criticalBlueUnitIds`. The runtime also passes `seed` and `requiredCells`, but in `scenario_red_policy.v2` they do not change scoring.

## Core Contract

- Red acts only on Red turns.
- Red has up to 2 actions per Red turn.
- If real legal actions exist, Red prefers real actions over `end_turn`.
- Red can evaluate one-action and two-action plans.
- A two-action plan is returned one action at a time: the policy chooses the first action now, then is called again after that action resolves.
- Action choice is deterministic. Same state means same action.
- The `seed` is recorded, but it does not randomize tie-breaks.
- Tie-break uses deterministic action/plan keys.

## Legal Action Source

Red receives legal actions from `scenarioStateEngine.getLegalActions`.

Legal Red actions include:

- move actions for active Red units;
- attack actions for active Red units;
- `end_turn`.

Inactive units do not act:

- `Commandant`;
- `Rock`;
- `Healer`;
- destroyed units.

## Plan Enumeration

The policy looks at remaining Red actions:

- if 2 actions remain, it scores focused one-action and two-action plans;
- if 1 action remains, it scores one-action plans;
- if 0 actions remain, it returns `end_turn`.

Focused plans include:

- every legal attack as a first action;
- the best fallback move toward the selected Blue target;
- moves that enable the same Red unit to attack on the second action;
- second-action attacks after a first action;
- same-actor move+attack plans;
- fallback movement when no attack follow-up exists.

This means Red is not exhaustive chess AI. It is a deterministic tactical policy shaped for scenario reliability.

## Priority Order

Plans are compared by rank, in this order:

1. Kill any Blue unit.
2. Kill a Blue unit immediately on the first action.
3. Kill more Blue units.
4. Reduce direct Blue threats against the Red Commandant.
5. Reduce projected Blue threats against the Red Commandant.
6. Deal more total damage to Blue units.
7. Advance toward the fallback Blue target.
8. Prefer attack over move, and move over end turn.
9. Avoid `end_turn`.
10. Slightly prefer attacks on `criticalBlueUnitIds`.
11. Stable deterministic plan key.

Important consequence: a kill can beat a non-killing attack on the most strategically important unit. If this is not desired for a specific scenario, the board must be designed so the wrong kill is unavailable, too slow, or strategically harmless.

## Commandant Threat Logic

Before scoring Red plans, the policy estimates Blue pressure on the Red Commandant.

It detects:

- direct Blue attackers that can attack the Commandant immediately;
- projected Blue attackers that can move once and then attack the Commandant;
- how much damage each direct/projected attacker could deal.

Red plans get priority for attacking or killing those threat units.

Direct threats outrank projected threats.

Killing a threat is worth more than merely damaging or targeting it.

Reducing higher Commandant damage is worth more than reducing lower Commandant damage.

## Critical Blue Units

`scenarioRedPolicy.criticalBlueUnitIds` marks Blue units that are important to the scenario contract.

Critical status is only a small boost, not an override.

It helps choose between otherwise similar attacks, but it does not beat:

- killing a Blue unit;
- killing immediately;
- reducing direct Commandant threats;
- reducing projected Commandant threats;
- dealing more damage.

Use `criticalBlueUnitIds` to stabilize close choices, not to force impossible behavior.

## Fallback Movement Target

When Red cannot make a meaningful attack or threat-reduction plan, it chooses a fallback Blue target and moves toward it.

The fallback target is selected in this exact order:

1. Blue unit with the lowest current HP.
2. If HP ties, Blue unit closest to the Red unit.
3. If distance ties, Blue unit that would deal more damage to the Red Commandant.
4. If still tied, stable id order.

Then Red chooses the legal move that reduces distance to that fallback target the most.

If multiple moves are equivalent, it uses the stable action key.

Design consequence: if Red has no real tactical job, it will still move toward a Blue unit by these rules. Do not leave Red with irrelevant material and expect it to "wait naturally."

## Action Type Preference

When strategic ranks are otherwise equal:

- attack is preferred over move;
- move is preferred over `end_turn`;
- `end_turn` is last.

This exists because Scenario Mode has a mandatory two-action rhythm. Red should not pass while it has a useful legal move or attack.

## Deterministic Tie-Break

All legal actions are sorted by stable keys before scoring.

The stable action key includes:

- action type;
- actor id;
- target id if any;
- destination or target cell;
- action id.

If two plans have equal tactical rank, the lower stable plan key wins.

This is why stable `scenarioUnitId` values matter. Changing ids can change tie-breaks even if the board looks identical.

## Policy Record

`chooseAction` returns both:

- selected action;
- record describing the decision.

The record includes:

- `policyVersion`;
- `policyHash`;
- `stateHash`;
- `candidateCount`;
- `planCandidateCount`;
- `scoredActions`;
- `selectedActionId`;
- `selectedPlan`;
- selected plan `rank`;
- selected plan `score`;
- reason codes.

Useful reason codes include:

- `kill_blue`;
- `kill_blue_immediate`;
- `target_direct_commandant_threat`;
- `target_projected_commandant_threat`;
- `damage_to_blue`;
- `fallback_toward_nearest_blue`;
- `attack_critical_blue`;
- `end_turn_penalty`;
- `non_red_noop`.

When judging a gameplay log, read this record instead of guessing.

## How To Design For This Policy

Good Scenario Mode design gives Red a real, deterministic job:

- guard a cell;
- chase a fragile support unit;
- punish a false route;
- block the finisher lane;
- remove a needed breaker;
- damage but not fully stop the correct finisher;
- force Blue to lure Red away.

Bad design leaves Red with no meaningful target and hopes it will behave "smartly."

If Red does something surprising, inspect:

- current Red legal actions;
- Blue direct/projected Commandant threats;
- current Blue HP values;
- Red distance to each Blue unit;
- `criticalBlueUnitIds`;
- selected plan record.

## What Not To Assume

Do not assume Red:

- knows the intended solution;
- knows the false path;
- knows which unit the designer calls "finisher" unless that matters through current board state or `criticalBlueUnitIds`;
- will stay still because moving is inconvenient for the puzzle;
- will protect a cinematic lane unless the scoring sees a reason;
- will choose nearest Blue before lower-HP Blue in fallback mode;
- will obey scenario-specific hardcoded movement.

The policy is deterministic, not narrative.

## Quick Debug Checklist

When a Red move looks wrong:

1. Read the log/record first.
2. Confirm it is Red's turn and how many actions remain.
3. List all legal Red attacks.
4. Check whether any attack kills Blue.
5. Check whether any target is a direct Commandant threat.
6. Check whether any target is a projected Commandant threat.
7. If no meaningful attack exists, compute fallback target:
   - lowest HP;
   - nearest;
   - highest possible Commandant damage;
   - stable id.
8. Check whether the chosen move reduces distance to that fallback target.
9. If behavior is still bad, change the scenario geometry/material, not the policy, unless the policy violates this brief.

## Direct Questions And Answers

### 1. Complete Spec Of `scenario_red_policy.v2`

`scenario_red_policy.v2` is a deterministic Scenario Mode Red action selector.

Inputs:

- normalized scenario state;
- legal actions from `scenarioStateEngine`;
- `criticalBlueUnitIds`;
- `seed`, recorded for trace only;
- `requiredCells`, passed through runtime config but not used for scoring in v2.

Output:

- selected first action;
- decision record with version, hash, state hash, candidates, scored actions, selected plan, rank, score, and reason codes.

Hard boundaries:

- no standard AI;
- no generator/tooling dependency;
- no scenario-id behavior;
- no solution-path lookup;
- no hardcoded move by level.

Scoring priorities are the `Priority Order` section above.

### 2. How Does Red Decide Between Movement And Attack?

Red does not choose "move vs attack" first. It scores plans.

If an attack plan kills, reduces Commandant pressure, or deals meaningful damage, it usually beats movement.

If no attack has meaningful impact, Red chooses a fallback move toward a selected Blue target.

When all strategic ranks are tied:

- attack beats move;
- move beats `end_turn`.

### 3. Can Red Attack First And Then Move, Like Blue?

Yes, if legal actions remain after the attack.

Red can execute action sequences across its two-action turn. The policy may choose an attack as action 1. After that attack resolves, the runtime calls the policy again for action 2.

However, the focused two-action planner mostly values:

- attack-first plans as immediate tactical actions;
- move+attack same-unit plans;
- fallback second movement when no attack follow-up exists.

So attack-then-move can happen through the second policy call, but it is not treated as a special scripted combo. It must still score as the best legal next action from the new state.

### 4. How Does Red Choose The Target?

For attacks, Red target choice comes from scored plan value:

- killing Blue;
- killing immediately;
- targeting direct Commandant threats;
- targeting projected Commandant threats;
- dealing damage;
- small boost if the target is in `criticalBlueUnitIds`;
- stable tie-break.

For fallback movement, Red first chooses a Blue target by:

1. lowest current HP;
2. nearest to that Red unit;
3. highest damage that Blue unit could deal to the Red Commandant;
4. stable id.

Then it chooses the legal move that best reduces distance to that target.

### 5. Are `criticalBlueUnitIds` Weights Or Hard Constraints?

They are weights/priorities, not hard constraints.

They add a tiny preference when the first action is an attack against a critical Blue unit.

They do not force Red to attack that unit, protect that unit's lane, move toward it, or ignore stronger tactical priorities.

### 6. What Exactly Do `requiredCells` Do?

In `scenario_red_policy.v2`, `requiredCells` do not affect scoring.

They are passed by `scenarioRedRuntime` and appear in trace/config metadata, but `scenarioRedPolicy.lua` does not read them when choosing actions.

Therefore they are not:

- cells to occupy;
- cells to protect;
- cells to avoid;
- cells to control;
- movement targets;
- hard constraints.

Treat them as scenario metadata/harness documentation unless future policy code explicitly consumes them.

Design consequence: never rely on `requiredCells` to make Red move to a cell. If Red must occupy, leave, block, or attack around a cell, the board state must make that action win under the scoring rules.

### 7. What Is The Tie-Breaker For Equivalent Red Moves?

Tie-break is deterministic and seed-independent.

The policy compares rank fields first:

- kills;
- immediate kills;
- kill count;
- direct threat priority;
- projected threat priority;
- damage;
- fallback advance;
- action type priority;
- avoid end turn;
- critical boost.

If still tied, it uses stable plan key/action key.

The stable key includes:

- action type;
- actor id;
- target id;
- row/col destination or target cell;
- action id.

There is no random seed tie-break.

### 8. If Red Does Not Have 2 Legal Actions, Does It Pass?

Red has up to 2 actions and should spend real legal actions when they exist.

If no real legal move or attack exists, Red uses `end_turn`.

If only one real action exists, Red can take that action; after it resolves, the next policy call may return `end_turn` if no second real action exists.

If a second real action exists and has meaningful impact or fallback movement value, Red should take it. This is why "exactly 2 actions" in design practice means: do not build scenarios that depend on Red voluntarily passing while legal useful actions exist.
