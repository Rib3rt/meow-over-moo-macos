# AI Passage Audit (Rules-to-Pipeline Hardening)

Source of truth: `Meow Over Moo! - Design document.pdf` (rev 1.6.4)

## Sprint Update (Points 1, 3, 4)

- Canonical positional component weights — **FIXED**
  - Runtime now reads positional component weights from canonical `SCORES.POSITIONAL.COMPONENT_WEIGHTS` with normalized fallback defaults; no silent all-ones collapse path remains.
  - Compatibility alias remains synced into legacy `EVAL.POSITIONAL.COMPONENT_WEIGHTS`.
  - References:
    - `ai_config.lua:339`
    - `ai_config.lua:1043`
    - `ai_decision.lua:1230`

- Draw-urgency pre-positioning/deploy gating — **FIXED**
  - Added explicit pre-positioning interaction gate to suppress passive positioning/deploy when draw/stalemate urgency is active and legal attack paths exist.
  - Draw-urgency engagement stage is now executed before passive positioning/deploy priorities.
  - Hard hub-defense condition bypasses this gate to preserve threat-first defense.
  - References:
    - `ai_config.lua:910`
    - `ai_decision.lua:7195`
    - `ai_decision.lua:8359`
    - `ai_decision.lua:8539`
    - `ai_decision.lua:9117`

- Dynamic 2→3 turn commandant threat horizon — **FIXED**
  - `analyzeHubThreat(state)` now adds projected threat analysis with turn-weighted aggregation and exposes:
    - `isUnderProjectedThreat`
    - `projectedThreatLevel`
    - `lookaheadTurnsUsed`
    - `threatsProjected`
  - Threat lookup now merges immediate and projected threats for response targeting.
  - Commandant threat response now triggers on projected danger and prefers neutralization counter-positioning over guard-only reposition when available.
  - References:
    - `ai_config.lua:720`
    - `ai_decision.lua:3991`
    - `ai_decision.lua:4215`
    - `ai_decision.lua:7602`
    - `ai_decision.lua:7720`

- Post-defense follow-up optimizer (threat-first continuation) — **FIXED**
  - When a commandant-threat action is already selected and one action remains, AI now runs a dedicated follow-up pass before generic priorities.
  - Follow-up ordering prefers threat neutralization/counter pressure, then guard/unblock/emergency supply.
  - Generic passive positioning/deploy is skipped while commandant threat remains active.
  - References:
    - `ai_decision.lua:6389`
    - `ai_decision.lua:7255`
    - `ai_decision.lua:7808`
    - `ai_decision.lua:8448`
    - `ai_decision.lua:8638`
    - `ai_decision.lua:9133`

## Strategic Planner Layer Update (Threat-First Siege)

- All-vs-defense bundle behavior — **FIXED**
  - Added `Priority01A` strategic defense stage before existing commandant defense path.
  - When strategic intent is `DEFEND_HARD`, AI builds a ranked defense bundle and reserves actions for neutralize/block-first responses.
  - Defense lock now suppresses non-defensive continuation until fallback completion.
  - References:
    - `ai_decision.lua:5374`
    - `ai_decision.lua:8906`
    - `ai_decision.lua:10732`

- Strategic siege setup/execution behavior — **FIXED**
  - Added persistent strategic planner state and intent classifier (`DEFEND_HARD`, `SIEGE_SETUP`, `SIEGE_EXECUTE`, `STABILIZE`).
  - Added deterministic siege package evaluation and plan advancement stage (`Priority13D`) before generic positioning/deploy.
  - Added planner telemetry logs: `StrategyIntent`, `PlanSelected`, `PlanAdvance`, `PlanAbort`, `DefenseBundle`.
  - References:
    - `ai_core.lua:254`
    - `ai_decision.lua:4982`
    - `ai_decision.lua:5058`
    - `ai_decision.lua:5486`
    - `ai_decision.lua:8986`
    - `ai_decision.lua:10853`

- Strict deploy impact gate under plan mode — **FIXED**
  - Deployment now routes through `getPlannedDeploymentCandidate(...)` for plan-aware gating.
  - Plan mode deployment requires role-fill or immediate defense counter/block, and rejects non-impact deployments outside strategy horizon.
  - Generic `Priority19` deployment now uses strategic gate instead of raw enhanced deployment finder.
  - References:
    - `ai_config.lua:754`
    - `ai_decision.lua:5320`
    - `ai_decision.lua:10234`
    - `ai_decision.lua:10255`

- Strict deploy anti-sacrifice hardening + ranged crossfire positioning — **FIXED**
  - Deployment gating now rejects tie-timing threat/impact and late-impact spawns (`MAX_IMPACT_TURN`) to reduce “spawn then die before contributing”.
  - Safe/risky move evaluators now apply explicit ranged-adjacent penalty and crossfire overlap bonus to bias toward coordinated lanes instead of isolated drift.
  - Added regression coverage for strict tie-timing deployment rejection.
  - References:
    - `ai_config.lua:555`
    - `ai_config.lua:800`
    - `ai_decision.lua:5457`
    - `ai_decision.lua:14455`
    - `ai_decision.lua:1551`
    - `ai_decision.lua:12984`
    - `scripts/ai_regression.lua:1988`

- Single-unit pressure bridge (skip reduction pass) — **FIXED**
  - Added `Priority10B` to prefer deterministic safe move+attack two-step pressure when only one acting unit has legal actions.
  - Purpose: reduce one-action turns that collapse into skip on slot two while preserving legal/action validity and deterministic ordering.
  - References:
    - `ai_config.lua:761`
    - `ai_decision.lua:9963`
    - `ai_decision.lua:10916`

## Rewrite Criteria

- Keep evolving the current priority engine while all of the following remain true:
  - draw rate improves and stays below target,
  - repeated hub-defense failure pattern is not persistent,
  - p95 decision latency remains within the 500ms budget without unmaintainable branching growth.
- Trigger rewrite planning only if at least one persists after two tuning cycles:
  - draw rate does not improve,
  - hub-defense failures continue in repeated self-play traces,
  - budget compliance requires complexity that materially harms maintainability.

## Passage Verdicts

1. Setup pipeline — **FIXED**
- Obstacle count/rows now contract-driven via `RULE_CONTRACT.SETUP.OBSTACLES`.
- Commandant zones now contract-driven via `RULE_CONTRACT.SETUP.COMMANDANT_ZONE`.
- Initial deployment count now contract-driven via `RULE_CONTRACT.SETUP.INITIAL_DEPLOY.COUNT`.
- References:
  - `gameRuler.lua:7`
  - `gameRuler.lua:260`
  - `gameRuler.lua:3287`
  - `gameRuler.lua:3360`
  - `gameRuler.lua:3743`

2. Turn-phase orchestration — **OK**
- Turn transition remains `commandHub -> actions` with commandant defense scheduled at turn start.
- AI continues to avoid duplicate commandant triggering in `commandHub` phase.
- References:
  - `gameRuler.lua:44`
  - `gameRuler.lua:1382`
  - `ai_decision.lua:128`

3. Mandatory 2-action legality — **FIXED**
- Added unified legal-action collection and mandatory fallback selector.
- Skip is now only used after iterating ranked legal-fallback candidates.
- Mandatory fallback path now permits legal zero-damage attacks.
- References:
  - `ai_decision.lua:709` (`collectLegalActions`)
  - `ai_decision.lua:844` (`getMandatoryFallbackCandidates`)
  - `ai_decision.lua:4261` (`ZERO_DAMAGE_ALLOWED_TAGS`)
  - `ai_decision.lua:5946` (`runPriority38PassTurn`)

4. Deployment action path — **FIXED**
- Deployment now participates in unified legal fallback.
- Simulated state now tracks `hasDeployedThisTurn` to enforce one deploy/turn during planning.
- References:
  - `ai_state.lua:35`
  - `ai_state.lua:224`
  - `ai_decision.lua:569`
  - `ai_decision.lua:2730`
  - `ai_decision.lua:3626`

5. Combat resolution correctness — **OK**
- Existing runtime logic already enforces melee capture-on-kill and ranged no-capture.
- Existing unit rules in `unitsInfo.lua` already cover LoS and passive modifiers.
- References:
  - `gameRuler.lua:2477`
  - `gameRuler.lua:2623`
  - `gameRuler.lua:2741`
  - `unitsInfo.lua:173`

6. Draw interaction semantics — **FIXED**
- Added explicit helpers:
  - `incrementNoInteractionCounterPerPlayerTurn()`
  - `resetNoInteractionCounter(reason)`
- Draw counter now increments once per player turn (from turn 10 onward).
- Counter now resets on unit attacks and commandant attacks, including zero-damage attacks.
- References:
  - `gameRuler.lua:1278`
  - `gameRuler.lua:1283`
  - `gameRuler.lua:1291`
  - `gameRuler.lua:745`
  - `gameRuler.lua:2477`

7. Priority engine hardening (no architecture change) — **FIXED**
- Priority order preserved.
- Added legal-fallback pass before skip fallback.
- Deterministic tie-break enabled in action randomizer.
- References:
  - `ai_decision.lua:5688`
  - `ai_profile.lua:79`

8. Duplicate / contradictory logic cleanup — **PARTIAL**
- Unified legal collector/fallback path added.
- Random-legal-action passage now reuses canonical legal collector instead of its own action-generation logic.
- Kill candidate generation is now centralized for:
  - direct kill attacks (safe and not-safe variants),
  - move+kill combos (safe and not-safe variants),
  - no-gate kill and move+kill variants.
- The legacy no-gate-specific collector (`collectNoGateKillCandidates`) was removed; all kill-path variants now use one canonical collector (`collectKillAttackCandidates`) with optionized thresholds/scoring, eliminating duplicated kill-loop logic and keeping deterministic sort behavior aligned across safe/not-safe/no-gate paths.
- Risky attack generation is now centralized for:
  - direct risky attacks,
  - risky move+attack combos.
- Multi-attacker targeting is now centralized for:
  - two-unit kill combinations,
  - two-attack commandant winning-condition check.
- Two-attacker combo construction now routes through one canonical builder (`findBestTwoAttackKillCombo(...)`) shared by:
  - `findTwoUnitKillCombinations(...)`,
  - winning-condition “destroy commandant with two attacks” logic,
  removing duplicated pair-evaluation/tie-break branches.
- Winning-condition move+attack construction is now centralized via `findWinningMoveAttackCombo(...)`, shared by:
  - single-unit move+attack hub-kill check,
  - move-plus-ranged-attack hub-kill check,
  removing duplicated move-loop/attack-loop branches and using simulated post-move board state for ranged line-of-sight evaluation.
- Winning-condition direct lethal-attack scans are now centralized via `findDirectLethalAttackOnTarget(...)`, shared by:
  - single-attack commandant-kill check,
  - single-attack last-enemy-unit-kill check,
  removing duplicated direct-attack traversal logic.
- Risk-tier direct attack scans now route through one canonical collector (`collectRiskyAttackCandidates(...)`) for:
  - risky valuable attacks,
  - risky expanded attacks,
  - desperate fallback attacks,
  with optionized gates (damage floor, safety requirement, special/1HP rejection, score function) replacing duplicated per-function attack loops.
- Neutral-building attack candidate traversal now routes through the same canonical legal-action collector (`collectLegalActions(...)`) already used by random/fallback selection, removing a separate direct attack-cell scan path and keeping attack legality source-of-truth unified.
- Move+attack traversal is now centralized via `collectAttackTargetEntries(..., mode=\"move\")` and reused by:
  - high-value move+attack opportunity collection (`collectMoveAttackOpportunityCombos(...)`),
  - risky move+attack candidate collection (`collectRiskyAttackCandidates(..., moveThenAttack=true)`),
  removing duplicated unit/move/attack-cell iteration and keeping move-legality filters aligned.
- Direct attack traversal is now centralized via `collectAttackTargetEntries(..., mode=\"direct\")` and reused by:
  - high-value direct attack collection (`collectHighValueAttackCandidates(...)`),
  - risky/desperate direct attack collection (`collectRiskyAttackCandidates(..., moveThenAttack=false)`),
  removing duplicated unit/attack-cell iteration and keeping direct-attack legality filters aligned.
- Direct and move attack-target collection now uses one core iterator (`collectAttackTargetEntries(...)`) with `mode` options (`direct`/`move`), eliminating duplicate target scanning and keeping damage/friendly-fire filters fully aligned.
- Legacy wrapper collectors were removed (`collectDirectAttackTargetEntries(...)` and `collectMoveAttackTargetEntries(...)`), and all call sites now bind directly to `collectAttackTargetEntries(...)`.
- Attack score-shaping components (damage multiplier, target value selection, and own-hub adjacency bonuses) are now centralized directly inside `getCanonicalAttackScore(...)`, and consumed by `getAttackOpportunityScore(...)` plus risk/kill candidate scoring paths.
- Risk-tier score call sites now route through canonical attack scoring directly (`getCanonicalAttackScore(...)`) for:
  - risky expanded attacks,
  - desperate fallback attacks,
  reducing duplicate scoreFn closures.
- Attack-prioritization context+scoring assembly is now centralized via `evaluateAttackOpportunityEntry(...)` and reused by:
  - high-value direct attacks (`collectHighValueAttackCandidates(...)`),
  - high-value move+attack combos (`collectMoveAttackOpportunityCombos(...)`),
  replacing duplicated `getAttackOpportunityContext -> shouldPrioritizeAttackContext -> getAttackOpportunityScore` pipelines.
- Attack-opportunity evaluation loops are now centralized through `collectEvaluatedAttackEntries(...)`, reused by:
  - `collectHighValueAttackCandidates(...)`,
  - `collectMoveAttackOpportunityCombos(...)`,
  removing duplicated entry-evaluate-append-sort scaffolding.
- High-value and move+attack profile option wiring is now centralized through:
  - `getHighValueAttackProfileOptions(...)`
  - `getMoveAttackOpportunityProfileOptions(...)`
  removing duplicate wrapper literals in `findHighValueSafeAttacks(...)`, `findHighValueAttacks(...)`, `findMoveAttackCombinations(...)`, and `findNotSoSafeMoveAttackCombinations(...)`.
- Repair candidate traversal is now centralized via `collectRepairActionCandidates(...)` and reused by:
  - survival direct repairs (`findSurvivalRepairActions(...)`),
  - survival move+repair combos (`findSurvivalMoveRepairActions(...)`),
  removing duplicated healer/target iteration and keeping repair-priority computation aligned.
- Repair result selection is now centralized through `selectUniqueEntries(...)` for:
  - single direct-repair pick (unique target),
  - single move+repair pick (unique target + unique healer),
  replacing duplicated local `usedTargets` / `usedRepairUnits` selection loops.
- Move+attack opportunity generation is now centralized for:
  - safe move+attack combinations,
  - not-so-safe move+attack combinations.
- Corvette LoS kill builder now uses a shared “best clearing move” selector instead of duplicated simulation passes.
- High-value attack generation is now centralized for:
  - high-value safe attacks,
  - high-value non-safe attacks.
- Move-state simulation for tactical move scoring is now centralized and reused by:
  - safe evasion evaluation,
  - beneficial no-damage move evaluation,
  - beneficial move evaluation.
- Safety threat evaluation is now centralized in `ai_safety.lua` via shared helpers:
  - `canUnitAttackFromPosition(...)`,
  - `hasLineOfSightIgnoringMover(...)`,
  - `appendMovingUnitOriginIfReachable(...)`,
  reducing repeated Cloudstriker/Artillery and self-blocking branches across:
  - suicidal movement checks,
  - suicidal attack checks,
  - ranged move+attack vulnerability checks,
  - complete safety checks.
- Removed dead/unused safety internals:
  - dropped unused `TWO_VALUE` constant,
  - dropped unused `threatSources` accumulation in complete safety analysis.
- `wouldBlockLineOfSight(...)` now resolves AI player ID from `self:getFactionId()` (with fallback), removing global-player coupling.
- Doomed-unit finisher scoring is now centralized in `ai_decision.lua` via:
  - `isDoomedFinisherAttack(...)`,
  - `getDoomedAttackPriority(...)`,
  and reused by both:
  - `findLastAttackForDoomedUnits(...)`,
  - `findLastMoveAttackForDoomedUnits(...)`.
- State move simulation is now centralized in `ai_decision.lua` via:
  - `simulateUnitMoveState(...)`,
  replacing duplicate local `simulateMove(...)` implementations in:
  - `getUncounteredThreatNearCommandant(...)`,
  - `findThreatCounterAttackMove(...)`.
- Enemy move-cell expansion for vacated-origin threat checks is now centralized in `ai_decision.lua` via:
  - `getEnemyMoveCellsWithVacatedTile(...)`,
  and reused in:
  - `calculatePositionSafetyScore(...)`,
  - `wouldUnitDieNextTurn(...)`.
- Self-blocking LoS threat handling in decision-time threat evaluation is now centralized via:
  - `isPositionBetweenOrthogonal(...)`,
  - `hasLineOfSightIgnoringUnit(...)`,
  and reused in `wouldUnitDieNextTurn(...)`.
- Positional delta evaluation for move scoring is now centralized and reused by:
  - safe evasion ranking,
  - risky-beneficial move ranking,
  - risky move value scoring.
- Eligibility filtering now routes through the shared `isUnitEligibleForAction(...)` gate across:
  - safe evasion,
  - beneficial no-damage moves,
  - survival repair collection,
  - survival move+repair collection.
- Threat-response eligibility now also routes through `isUnitEligibleForAction(...)` (with `requireAlive` option) in:
  - uncountered-threat scan near Commandant,
  - threat counter-attack positioning,
  - commandant guard move selection,
  removing duplicated per-function ally-eligibility predicates.
- Threat-response move-cell gating now routes through shared `isOpenSafeMoveCell(...)` in:
  - uncountered-threat scan near Commandant,
  - threat counter-attack positioning,
  - commandant guard move selection,
  removing duplicated destination-occupied + move-safety guard branches.
- Threat-response attack reach checks now route through shared `canUnitDamageTargetFromPosition(...)` in:
  - uncountered-threat scan near Commandant (direct + move-then-attack),
  - threat counter-attack positioning,
  removing duplicated attack-cell loops and aligning positive-damage gating.
- Targeted lethal/reach attack checks now also route through `canUnitDamageTargetFromPosition(...)` in:
  - attacker collection against a fixed target (`collectAttackersAgainstTarget(...)`),
  - direct lethal target checks (`findDirectLethalAttackOnTarget(...)`),
  - winning move+attack target checks (`findWinningMoveAttackCombo(...)`, single-unit and ranged-shooter paths),
  removing duplicated “scan attack cells for one target” loops.
- Objective/support targeted reach checks now also route through shared helpers:
  - `canUnitDamageTargetFromPosition(...)` in objective mobility progress (`calculateObjectiveMobilityBonus(...)`) and ranged support follow-up,
  - `simulateUnitMoveState(...)` in ranged support follow-up move simulation,
  removing duplicated local attack-cell scans and ad-hoc state-copy move simulation.
- Move candidate collection now routes through shared `collectMoveEvaluationEntries(...)` across:
  - safe evasion selection (`findSafeEvasionMoves(...)`),
  - beneficial no-damage moves (`findBeneficialNoDamageMoves(...)`),
  - beneficial safe moves (`findBeneficialMoves(...)`),
  - risk-tolerant beneficial moves (`findNotSoSafeBeneficialMoves(...)`),
  - risky vulnerable moves (`findRiskyMoves(...)`),
  removing duplicated unit-eligibility / move-loop / safety-gate scaffolding in these passages.
- Risk-vulnerability checks now route through shared `isVulnerableMovePosition(...)` in:
  - risk-tolerant beneficial moves,
  - risky moves,
  - trap-value calculation.
- Two-step priority execution (move+attack / move+repair / dual attacks) now routes through shared helpers:
  - `applyQueuedAction(...)`
  - `applyTwoStepAction(...)`
  to reduce duplicated add/apply/rollback branches in the priority runner.
- Single-step priority execution now also routes through `applyQueuedAction(...)` across kill/move/deploy passages, reducing duplicated add+log+state-update blocks.
- Support-internal execution paths now also route through `applyQueuedAction(...)` in:
  - ranged support follow-up,
  - support reinforcement move commit,
  while preserving support debug hooks.
- Support pathfinding checks now route through shared `hasLimitedClearPath(...)` for:
  - ranged support follow-up target access,
  - support reinforcement path validation,
  removing duplicated bounded-BFS path checks.
- Priority 38 skip/fallback now routes through `applyQueuedAction(...)` with `stateMode="none"` for pass actions, so low-level queue insertion is centralized and state mutation remains explicit.
- Direct `addActionSafely(...)` calls are now fully centralized behind shared executors (`applyQueuedAction` / `applyTwoStepAction`) except the helper internals.
- Removed unused helper `selectMandatoryFallbackAction(...)`; mandatory fallback now flows exclusively through `getMandatoryFallbackCandidates(...)` inside Priority 38.
- Deterministic score sorting utility is now centralized and reused by:
  - mandatory legal fallback ranking,
  - random legal action ranking,
  - supply deployment ranking,
  - kill candidate ranking (direct + move/kill),
  - corvette LoS combo ranking,
  - high-value attack ranking,
  - move+attack opportunity ranking,
  - risky attack ranking,
  - repair and move+repair ranking,
  - neutral building and risky-expanded attack ranking,
  - no-gate kill ranking,
  - risky move candidate ranking,
  - safe evasion ranking,
  - risk-tolerant beneficial move ranking.
- Blocking-objective move evaluation now reuses shared orthogonal-between LoS helper, precomputes enemy/allied lists once per call, precomputes enemy-hub free deployment cells once per call, and ranks all blocking candidates via deterministic sort utility.
- Beneficial/risky move scoring now reuses shared weighted strategic score helper (`improvement + repair + threat`) and shared free-adjacent delta scoring helper, removing duplicated arithmetic branches in:
  - safe beneficial moves,
  - safe no-damage beneficial moves,
  - risk-tolerant beneficial moves.
- Strategic move score assembly is now centralized in `scoreStrategicMove(...)` and reused by:
  - `findBeneficialMoves(...)`,
  - `findBeneficialNoDamageMoves(...)`,
  - `findNotSoSafeBeneficialMoves(...)`,
  removing duplicate threat/repair/threshold pipelines and eliminating double-applied commander exposure penalty in the no-damage branch.
- Attack scoring now has a canonical base path in `getCanonicalAttackScore(...)`, with `getAttackOpportunityScore(...)` and risk-tier/kill callers routed through shared base damage/value composition.
- Kill candidate collection (`collectKillAttackCandidates(...)`) now reuses shared attack entry collection (`collectAttackTargetEntries(...)` with direct/move modes) instead of maintaining a separate unit/cell traversal path.
- Kill/risky candidate pipelines now each use a single attack-entry pass (mode-selected) instead of separate direct vs move branches before evaluation.
- Risky move+attack safety checks now evaluate attack safety from the projected post-move attacker position (not stale pre-move coordinates), aligning kill/risk pipelines on the same legality model.
- Regression coverage added for projected move+attack safety semantics:
  - `risky_move_attack_safety_uses_projected_attacker_position`
  - `risky_move_attack_attacker_will_die_flag_uses_projected_position`
- Risky-move evaluation now runs through one shared component pass (`evaluateRiskyMoveComponents`) reused by:
  - risky move value scoring,
  - risky move reason tagging,
  avoiding duplicate trap/threat recalculations per candidate.
- Threat projection is now centralized through shared projected-attacker helpers:
  - `buildProjectedThreatUnit(...)`
  - `evaluateThreatFromProjectedPosition(...)`
  and reused by:
  - `calculateNextTurnThreatValue(...)`
  - `calculateThreatBonus(...)`
  so direct vs projected threat scoring no longer diverges by attack-cell lookup path.
- Reachability scoring now also routes through the same projected-target collector path:
  - `collectProjectedThreatTargets(...)` drives both current-reach and next-turn-reach sets in `calculateNextTurnReachabilityBonus(...)`,
  eliminating its previous standalone attack-cell loop implementation.
- Full duplicate-removal sweep across all priority helpers is complete for the current release baseline.
- References:
  - `ai_decision.lua:336`
  - `ai_decision.lua:1745`
  - `ai_decision.lua:4603`
  - `ai_decision.lua:4625`
  - `ai_decision.lua:4846`
  - `ai_decision.lua:4881`
  - `ai_decision.lua:6400`
  - `ai_decision.lua:5258`
  - `ai_decision.lua:5688`
  - `ai_decision.lua:5720`
  - `ai_decision.lua:5758`
  - `ai_decision.lua:5839`
  - `ai_decision.lua:6011`
  - `ai_decision.lua:6032`
  - `ai_decision.lua:6190`
  - `ai_decision.lua:6391`
  - `ai_decision.lua:709`
  - `ai_decision.lua:844`
  - `ai_decision.lua:915`
  - `ai_decision.lua:1773`
  - `ai_decision.lua:1820`
  - `ai_decision.lua:1828`
  - `ai_decision.lua:1894`
  - `ai_decision.lua:4118`
  - `ai_decision.lua:6677`
  - `ai_decision.lua:6957`
  - `ai_decision.lua:7023`
  - `ai_decision.lua:7116`
  - `ai_decision.lua:7229`
  - `ai_decision.lua:7341`
  - `ai_decision.lua:7486`
  - `ai_decision.lua:8034`
  - `ai_decision.lua:8604`
  - `ai_decision.lua:9029`
  - `ai_decision.lua:9175`
  - `ai_decision.lua:9271`
  - `ai_decision.lua:9592`
  - `ai_decision.lua:9984`
  - `ai_decision.lua:10131`
  - `ai_decision.lua:10227`
  - `ai_decision.lua:10356`
  - `ai_decision.lua:10462`
  - `ai_decision.lua:10914`
  - `ai_decision.lua:10998`
  - `ai_decision.lua:11050`
  - `ai_decision.lua:11055`
  - `ai_decision.lua:11085`
  - `ai_decision.lua:11188`
  - `ai_decision.lua:1010`
  - `ai_decision.lua:1227`
  - `ai_decision.lua:8139`
  - `ai_decision.lua:8230`
  - `ai_decision.lua:10566`
  - `ai_decision.lua:10745`
  - `ai_decision.lua:10829`
  - `ai_decision.lua:10952`
  - `ai_decision.lua:6768`
  - `ai_decision.lua:6787`
  - `ai_decision.lua:6843`
  - `ai_decision.lua:6880`
  - `ai_decision.lua:7031`
  - `ai_decision.lua:10953`
  - `ai_safety.lua:79`
  - `ai_safety.lua:146`
  - `ai_safety.lua:204`
  - `ai_safety.lua:414`
  - `ai_safety.lua:855`
  - `ai_decision.lua:8305`
  - `ai_decision.lua:8332`
  - `ai_decision.lua:8336`
  - `ai_decision.lua:8367`
  - `ai_decision.lua:8451`
  - `ai_decision.lua:8574`
  - `ai_decision.lua:9229`
  - `ai_decision.lua:2947`
  - `ai_decision.lua:3047`
  - `ai_decision.lua:3067`
  - `ai_decision.lua:3084`
  - `ai_decision.lua:10019`

9. Performance and determinism — **FIXED (runtime instrumentation)**
- Deterministic tie-break enabled.
- Runtime latency instrumentation added (`lastDecisionLatencyMs`, rolling `median/p95`) with budget warning.
- Added benchmark helper API: `benchmarkDecisionState(state, iterations)` for repeat-run determinism and latency checks on identical state.
- References:
  - `ai_profile.lua:103`
  - `ai_decision.lua:497`
  - `ai_decision.lua:506`
  - `ai_decision.lua:3527`

## Notes
- This pass intentionally keeps the current priority-engine architecture.
- Runtime benchmark protocol: `docs/ai_benchmark_protocol.md`.
- Regression harness: `scripts/ai_regression.lua`.
- Latest regression output: `docs/ai_regression_report.md`.
- Remaining work is primarily deeper duplicate-pruning in lower-priority tactical helpers.

## Planner Tuning (2026-02-18)
1. Deploy anti-sacrifice gate — **FIXED**
- Added strategy-level deploy sync controls to reject early-threat deployments that do not produce immediate impact, and reject threat-before-impact cases.
- Added non-defense healer-deploy block in plan-aware deployment selection.
- References:
  - `ai_config.lua` (`SCORES.STRATEGY.DEFENSE.HARD_TRIGGER_TURNS`, `SCORES.STRATEGY.DEPLOY_SYNC.*`)
  - `ai_decision.lua` (`getPlannedDeploymentCandidate`)

2. Guard drift under active siege plan — **FIXED**
- Commandant guard reposition (`Priority13`) now respects active strategic-plan suppression to prevent non-plan defensive drift when siege coordination is active.
- Reference:
  - `ai_decision.lua` (`runPriority13CommandantGuardMove`)

3. Draw/no-interaction anti-loop hardening — **FIXED**
- Added forced interaction attack conversion under stalemate pressure (not only critical draw urgency), with hub-threat guard.
- Added low-impact move penalty for repeated no-progress reposition patterns during no-interaction streaks.
- Added siege move convergence bias so primary/secondary plan units prefer 1–2 turn hub-pressure lanes.
- References:
  - `ai_config.lua` (`DRAW_URGENCY.ENFORCE_ATTACK.*`, `DRAW_URGENCY.STALEMATE_PRESSURE.LOW_IMPACT_*`)
  - `ai_decision.lua` (`enforceDrawUrgencyAttackFallback`, `getLowImpactMovePenalty`, `runPriority22bDrawUrgencyEngagement`, `buildSiegeActionBundle`)
