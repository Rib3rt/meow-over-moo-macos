# AI Math Review (2026-02-18)

## Goal
Audit decision math for over-dominant terms, marginal terms, and gates that suppress useful options.

## Findings

1. Over-dominant hard-defense trigger
- Problem: `DEFEND_HARD` intent could activate from low hub HP alone, even when no immediate/projected threat existed.
- Effect: Strategy layer over-locked into defense mode and suppressed normal siege flow.

2. Over-restrictive deploy threat timing gates
- Problem: deploy candidates in `SIEGE_SETUP` were rejected by threat-timing tie/lead checks even when hub threat was not active.
- Effect: Many `SUPPLY_DEPLOY: Rejected by threat gating` outcomes; deploy math was effectively muted in non-defensive turns.

3. Ranged adjacency drift in strategic movement
- Problem: convergence incentives could still push ranged units into adjacent cells with no immediate turn-1 payoff.
- Effect: low-value adjacency exposure and poor setup quality.

4. Redundant move+attack in threat response (already fixed earlier)
- Problem: move+attack could be chosen when direct attack already existed with equal lethality/damage.
- Effect: wasted move budget.

## Changes Applied

### 1) Hard-defense trigger normalized
- File: `ai_decision.lua`
- Change: `computeStrategicIntent()` now requires detected pressure for low-HP hard-defense escalation.
- New behavior: low HP alone no longer forces `DEFEND_HARD` without immediate/projected threat signal.

### 2) Deploy threat timing gating made context-aware
- Files: `ai_config.lua`, `ai_decision.lua`
- Added config flags:
  - `SCORES.SUPPLY_DEPLOYMENT.THREAT_GATING.STRICT_GATING_REQUIRES_HUB_THREAT = true`
  - `SCORES.STRATEGY.DEPLOY_SYNC.STRICT_THREAT_TIMING_REQUIRES_HUB_THREAT = true`
- Behavior:
  - Tie/lead threat-timing rejection is strict when hub is threatened.
  - Same gates are relaxed in non-threat siege/setup flow.

### 3) Strategic ranged adjacency control (from current pass)
- Files: `ai_config.lua`, `ai_decision.lua`
- Added/used:
  - `RANGED_ADJACENCY_PENALTY_MULT`
  - `RANGED_ADJACENCY_HARD_AVOID_PRIMARY_SECONDARY`
  - `RANGED_ADJACENCY_ALLOW_IF_CONVERGENCE_TURN1`
- Behavior: primary/secondary ranged plan moves avoid adjacent drift unless immediate convergence (turn-1) is achieved.

### 4) Supply defense impact scoring tightened (from current pass)
- Files: `ai_config.lua`, `ai_decision.lua`
- Added/used:
  - `BLOCK_PRIMARY_THREAT_BONUS`
  - `COUNTER_THREAT_TURN1_BONUS`
  - `COUNTER_THREAT_TURN2_BONUS`
- Behavior: line-blocking/counter-turn defensive deploys rank ahead of low-impact safe spawns.

## Regression Coverage Added/Updated
- `commandant_move_attack_skips_redundant_reposition_when_direct_attack_exists`
- `supply_deploy_prefers_primary_threat_line_block_under_immediate_hub_threat`
- `strategic_plan_move_avoids_ranged_adjacent_without_turn1_convergence`
- `low_hub_hp_without_detected_threat_does_not_force_defend_hard`
- `deploy_allows_early_threat_before_impact_when_hub_not_threatened_under_siege_plan`
- `deploy_rejects_early_threat_before_impact_when_hub_threatened_under_siege_plan`
- `deploy_allows_threat_tie_impact_when_hub_not_threatened_under_siege_plan`
- `deploy_rejects_threat_tie_impact_when_hub_threatened_under_siege_plan`

## Validation Snapshot
- `lua scripts/ai_regression.lua`
  - Passed: 53
  - Failed: 0
  - Benchmark snapshot: deterministic true, p95 decision latency ~10.454ms (well under 500ms budget)
