# Greenfield Plan: Verified Retro-Generator For Scenario Mode

## Goal

Build a scenario-only pipeline that generates difficult but provably solvable scenarios from seeds.

The primary construction method is retro-generation from a mate position, but the generator must not merely find a way to kill the Red Commandant. The generator must create a tactical puzzle: an initial board, an objective, a hidden solving mechanism, plausible false lines, real Red pressure, and a solver proof that the solution exists within the declared turn limit.

Target internal flow:

1. Internal designer clicks `New Scenario`.
2. The tool chooses a new seed, turn limit, Red Commandant anchor, finisher, and tactical constraints.
3. The generator builds a tactical puzzle candidate.
4. The contract validator checks structural legality.
5. The solver proves a winning line within N turns.
6. The solver proves the documented false lines.
7. The Scenario Red Policy credibility harness validates Red behavior.
8. The quality evaluator scores difficulty and novelty.
9. The scenario is accepted, or the attempt returns `not_generated` with useful diagnostics.
10. Accepted scenarios can be opened in the editor for manual review and promotion.

This generator, solver, batch runner, proof tooling, and diagnostics are internal/local tools only. They are not part of the package shipped to the final user.

The final user package may include only:

- promoted scenario files;
- data required to play them;
- the scenario runtime loader;
- the `Scenario Red Policy`, because it is part of the scenario contract.

The standard game, standard rules, and standard AI must not be modified.

## Generator Definition

A scenario generator must not "find a way to kill the Commandant". That is only the final objective, like the exit of an escape room.

A scenario generator must create a new tactical situation where the player has to discover which mechanism makes the mate possible.

Contract definition:

The scenario generator is a procedural system that, given a new seed, builds a new tactical puzzle: initial board, objective, hidden solving mechanism, plausible false lines, real Red pressure, and solver proof that the solution exists within the declared limit.

The generator is not creating "the death of the Commandant". It is creating:

- the lock;
- the key;
- the path to the key;
- the false trails;
- the risk;
- the reason why one sequence works and alternatives fail.

Short contract version:

A new seed should normally produce a new tactical problem, not a new arrangement of the same problem. A scenario is new only if it changes the mechanism the player must discover to make the mate possible.

## New Scenario Semantics

Each `New Scenario` press must use a new seed to procedurally construct a new tactical puzzle.

Novelty must come from the generative space itself: mechanism family, micro-interaction composition, unit roles, false lines, Red pressure, line constraints, tempo, and position. Novelty must not come from comparing against previous scenarios.

The novelty check is only a safety net against rare collisions. It is not the mechanism that prevents repetition.

## Guiding Philosophy

The solution must be readable in hindsight but not obvious in advance. The desired difficulty comes from discovering the tactical mechanism that makes the mate possible.

Operational implications:

- **No static damage clock**: if the mate is only repeated damage added turn after turn, it is not a puzzle.
- **Yes tactical mechanism**: the solution must create or activate something that was not available before.
- **Yes plausible false lines**: at least one natural-looking choice must fail because it blocks the mechanism.

Unacceptable:

- The generator changes only coordinates, names, finisher, HP, or Commandant position while keeping the same mechanism.
- The generator often produces equivalent scenarios and hopes the history filter rejects them.
- The gameplay is only damage accumulation on the Commandant.

## Forbidden Failure Modes

These cases must fail tests, quality gates, or batch gates. They are not "weak scenarios"; they are evidence that the generator is cheating.

- Two or more already-ready Blue units repeatedly shoot the Commandant with no tactical transformation between attacks.
- The finisher only moves for free and then shoots, with no cost, risk, ordering constraint, removed blocker, Red threat, or trade-off.
- The support unit is already in position from the start and only adds damage.
- Red creates cosmetic pressure that changes no Blue decision, false line, timing, or exactness.
- Novelty history rejects almost all valid seeds. This means the generative space is repetitive.
- Micro-interactions appear almost always in the same order.
- The finisher library is used as a macro-template, meaning the finisher already determines the whole scenario structure.
- The solution is a multi-unit sequence of attacks on the Commandant without intermediate lock, key, path, risk, and payoff.
- Metadata lists micro-interactions that do not change replay, false lines, Red response, or exactness.

Each forbidden failure mode must have at least one negative fixture before the generator is implemented.

## Non-Negotiable Scenario Contract

Every valid generated scenario must satisfy these constraints:

- Blue to move.
- Objective: destroy the Red Commandant within N turns.
- N is between 3 and 10.
- One scenario turn means Blue turn plus Red response.
- Failure occurs at the start of Blue turn N+1.
- No Blue Commandant.
- Exactly one Red Commandant.
- No Healer in scenario generation.
- The Red Commandant starts in a random cell from `A1-H2`.
- Rocks are neutral entities, `player = 0`, and there may be more than four.
- No supply management.
- Units and Commandant may start with arbitrary HP, but never above their maximum HP.
- Blue units may start with `hasActed = true`; under the current contract wording this means they cannot act on the first Blue turn.
- Destroying all Red units is not enough if the Red Commandant survives.
- Victory is only achieved by destroying the Red Commandant.
- All other tactical rules must match the official scenario rules.

## Pipeline States

Scenario states are strict. A scenario cannot skip states.

- `draft`: generated, but not proven. Raw material only.
- `candidate`: declared line replays legally, but proof is incomplete.
- `certified`: contract validation, solver proof, false-line proof, and `Scenario Red Policy` exactness pass.
- `approved`: certified scenario that also passes quality gates and manual editorial review.

Only `approved` scenarios may enter the promoted scenario list. `certified` is not enough if the scenario is trivial, repetitive, a damage clock, or built from decorative micro-interactions.

## Safety Certificate

A scenario is not safe because it "looks solvable". It is safe only if the pipeline emits a verifiable certificate.

Minimum certificate content:

- full seed;
- contract version/hash;
- rules kernel version/hash;
- `Scenario Red Policy` version/hash used at runtime;
- `Defensive proof` domain version/hash when `All-legal proof` was not used;
- full initial state;
- Red Commandant starting cell;
- finisher;
- turn limit;
- hidden tactical mechanism declared at technical level;
- tactical fingerprint;
- lock, key, path, risk, false trail, and payoff description;
- full winning line;
- Red responses computed by the `Scenario Red Policy` on the winning line;
- proof domain used and version/hash;
- search result;
- documented false lines;
- proof that each documented false line, with Red response computed by policy and/or required defensive domain, loses by unit destruction, timeout, or impossibility to finish in time;
- readable explanation of why the winning line works.

Without a certificate, the scenario remains editorial draft material and cannot be promoted.

## Architecture

Generation must not depend on random playtesting or on AI observed as a black box.

There are three distinct layers:

1. **Rules Kernel**: simulates scenario rules legally.
2. **Scenario Red Policy**: deterministic, credible, scenario-only Red behavior.
3. **Solver/Verifier**: proves Blue has a winning strategy within N turns against the chosen Red proof domain and checks runtime exactness against the policy.

The `Scenario Red Policy` is part of the scenario contract. Generation, certification, solution export, and runtime must use the same versioned policy.

The `Scenario Red Policy` must not be scripted around the solution. The player is free to explore mistakes, strange moves, deviations, and lines not documented editorially. Red must respond to the current real state, not to a predefined timeline.

The solver is not AI. It is proof. It may be stricter than runtime policy and explore many or all legal Red defenses, but runtime credibility is always checked against the `Scenario Red Policy`, never against the standard AI.

## Standard AI Exclusion

The standard AI must not be used in scenarios, either for proof or runtime.

Reasons:

- it may be slow;
- it may change later for normal-game reasons;
- it may have tie-breaks not designed for scenarios;
- it must not be modified;
- it would create an unacceptable divergence: certified against one policy, played against another.

The standard AI is not oracle, not harness, not fallback, and not scenario runtime.

## Technical Target Pipeline

The scenario generator is a retro-forward search engine. It explores many states, builds candidates, simulates them, rejects most of them, ranks the survivors, and accepts only real tactical puzzles.

Target pipeline:

```text
new seed
  -> strong random choices
  -> retro-construction from mate
  -> forward simulation
  -> strict solver
  -> false-line proof
  -> Scenario Red Policy credibility
  -> difficulty/novelty scoring
  -> accepted scenario or not_generated
```

Strong random choices must include at least:

- mechanism family;
- micro-interaction density profile;
- lock type;
- tactical key;
- Red pressure;
- main false line;
- finisher;
- Red Commandant cell.

If the seed changes only coordinates or HP, generation has failed semantically even if the candidate is legal.

`not_generated` is valid for a single attempt, not as the desired workflow result. The internal tool must continue with derived seeds, backtracking, or new micro-interaction profiles until it produces an accepted scenario or a useful diagnostic failure. Long processing is acceptable. Time spent without scenario, proof, or useful rejection reasons is not.

## Engine Modules

These modules describe what the generation engine must do. They do not mandate a language.

Allowed implementation strategies:

- pure Lua, if practical;
- C for hot paths, if Lua is not enough;
- Lua/C hybrid, with Lua orchestrating and C accelerating search/simulation.

C is an optional accelerator, not a contract requirement. The contract requirement is certified, explainable scenario production.

### State Engine

Compact state representation:

- 8x8 grid;
- unit array;
- type, HP, position, and player;
- current player;
- scenario turn;
- flags such as `hasMoved`, `hasActed`, and used actions;
- incremental state hash.

It must support very fast copies or, preferably, move `apply/unapply`. This is required for solver, beam search, and false-line proof.

### Legal Move Generator

Generates all legal scenario actions:

- move;
- attack;
- end turn;
- Blue action sequences from 0-2 actions if the ruleset allows them.

`repair` is excluded from the first scenario-generation mode because Healer is not used. If a future official non-Healer rule introduces repair, it must be explicitly added to contract and tests.

This is a hot path. It must be deterministic and testable.

### Rules Parity Layer

The generation engine must not invent rules different from scenario rules.

Allowed options:

- single Lua engine with complete rule fixtures;
- C proposal engine with Lua final validation;
- C full rules engine with parity tests against Lua;
- hybrid engine where every Lua/C boundary has parity tests.

Absolute rule:

If two rule implementations diverge, the candidate becomes `unknown` or is rejected. Never approve it.

### Retro-Generator Core

Starts from the final position:

- Red Commandant dies on turn N;
- finisher X from cell Y makes the final hit;
- the mate is legal in the mate-position.

Then works backward:

- how does the finisher reach that point?
- which unit creates or prepares the tactical key?
- which blocker must be removed?
- which false trail looks natural?
- which Red threat creates difficulty?
- which HP values prevent early wins?

This is not level painting. It is mechanism construction.

### Constraint Pre-Check

Before full solver search, the engine rejects obviously dead or poor candidates:

- insufficient maximum damage;
- mate already possible too early;
- units out of range;
- irreparably blocked lines;
- Commandant outside `A1-H2`;
- illegal false line;
- Red has no role;
- solution is only damage clock;
- tactical fingerprint too poor.

### Solver And Red Proof Domains

The solver is proof, not AI:

- Blue node: Blue chooses.
- Red node: Red replies with every response in the selected proof domain.
- Blue must win against every considered Red response.
- Search depth is limited to N scenario turns.

Configurable Red domains:

- **All-legal proof**: every legal Red response, when tractable.
- **Defensive proof**: every relevant defensive Red response, selected by a general function of the state, not by the desired winning line.
- **Runtime exactness proof**: verifies that the runtime `Scenario Red Policy` chooses a credible response already covered by the proof, and reruns proof if it chooses a different response.

`Defensive proof` is necessary for performance, but dangerous unless formalized. The defensive domain must be a general, versioned, deterministic function of the current state. It must not know the generator's desired response, winning line, solution turn, or which move would make the puzzle true.

A Red move must be included in the defensive domain if at least one condition is true:

- it reduces or prevents future damage to the Commandant;
- it kills or damages a critical Blue unit;
- it blocks, occupies, or clears a line/cell required by the mechanism;
- it moves a Red unit away from a false vulnerability;
- it protects the Commandant;
- it creates an immediate threat against finisher, support, or key unit;
- it prevents a declared micro-interaction;
- it gains time against the N-turn limit;
- it is chosen by the `Scenario Red Policy`;
- it is considered equivalent by the policy's versioned score/tie-break logic.

For every legal Red move at a Red node, the defensive-domain classifier must emit a decision record:

```text
DefensiveDomainDecision:
  red_action:
  decision: include | exclude | unknown | fallback_all_legal
  reason_codes:
  predicate_inputs:
  predicate_results:
  policy_score_band:
  equivalence_reason:
  domain_version:
```

`exclude` is allowed only when every inclusion predicate is false and the move is not equivalent to the policy choice. Equivalence must be narrow and versioned: same tactical class, score within a declared epsilon, and no different effect on Commandant safety, critical Blue units, required cells/lines, timing, or declared micro-interactions. If equivalence cannot be proven, the decision is `unknown` or `fallback_all_legal`.

If the defensive domain cannot safely decide whether a relevant Red move must be included, the node result is `unknown` or the solver must fall back to `All-legal proof`. Never declare `forced_win` by omitting inconvenient legal Red defenses.

Required solver outputs:

- `forced_win`;
- `unsolved`;
- `unknown`;
- winning line;
- losing first moves;
- earliest win round;
- refutations.

### Transposition Table / Cache

Mandatory.

Canonical hash includes:

- board;
- units;
- HP;
- player;
- turn;
- action flags;
- mechanism state if needed.

Cache stores:

- state win/loss/unknown;
- depth;
- best line;
- refutation;
- false-line result;
- `Scenario Red Policy` response for critical states.

Without cache, search explodes.

### Pruning

Cut early when:

- Blue can no longer deal enough damage;
- Commandant is too vulnerable too early;
- line is attack-only;
- second attacker is free from the start;
- Red does not change the problem;
- candidate is semantically poor;
- mechanism is already active without tactical work.

Pruning must not silently remove acceptable candidates. If a prune is not provably safe, the result is `unknown`, not `reject`.

### Beam Search

During retro-construction, keep only the best K candidates.

Partial score:

- tactical transformation;
- non-trivial difficulty;
- plausible false lines;
- Red pressure;
- semantic diversity;
- compact proof;
- hindsight readability.

### Scenario Red Policy Credibility Harness

The proof belongs to the solver, but Red must be credible against the actual scenario-only runtime policy.

Correct harness:

- engine produces critical states;
- Lua calls the versioned `Scenario Red Policy`;
- response is cached;
- if policy ignores an obvious lethal threat, attacks irrelevant targets, fails to express pressure, or answers artificially, the candidate is rejected or marked `unknown`;
- if policy diverges from the response assumed by the candidate, proof is rerun against the runtime response.

This harness never calls standard AI.

### Novelty Native + History Safety

The generator must be varied by construction.

Fingerprint includes:

- mechanism;
- micro-interactions;
- local order and dependencies;
- finisher role;
- false line;
- Red pressure;
- solution shape;
- board transformation;
- mate structure.

History is only an airbag against rare collisions. If it triggers often, the generative space is too poor.

Initial native variety metrics:

- On a history-free batch of at least 50 `certified` scenarios, at least 60% must have distinct tactical fingerprints.
- On a history-free batch of at least 100 `certified` scenarios, no single fingerprint may represent more than 10%.
- If more than 15% of otherwise valid candidates are rejected only by novelty check, the generative space is considered failed.
- If more than 30% of certified scenarios use the same micro-interactions in the same local order, the library or sampler must be revised.

These are initial calibration targets. They may be adjusted only after measured reports, not to let a weak batch pass.

### Output Dossier

The generator must not say "I found a board". It must return a dossier:

- scenario;
- winning proof;
- false-line proofs;
- exactness proof against `Scenario Red Policy`;
- Red proof domain and version/hash;
- `Scenario Red Policy` credibility records;
- semantic fingerprint;
- quality score;
- rejection reasons if failed;
- `not_generated` for a single failed attempt.

In the normal workflow, `not_generated` does not end generation. It feeds retry with derived seed, new micro-interaction composition, or deeper backtracking. The expected operational result is an accepted scenario.

## Computable Semantics Requirement

Qualitative terms are not allowed to remain narrative labels. Terms such as `critical Blue unit`, `required cell`, `gains time`, `real pressure`, `position gained`, `prevents a micro-interaction`, and `non-decorative` must become computable properties in schema, solver, and quality evaluator.

This is a pre-code gate. Before implementing the generator, solver heuristics, quality evaluator, or promotion pipeline, the project must formalize the predicates and schemas that make these qualitative terms measurable.

If a term affects certification, rejection, scoring, or proof-domain inclusion, it must be implemented as one of:

- a predicate over state and horizon;
- a feature emitted by solver analysis;
- an ablation result;
- a versioned score component;
- a validator rule;
- a proof-domain classifier.

Examples of required computable definitions:

- `critical_blue_unit(state, unit, horizon)`: true if removing, disabling, killing, or delaying that unit changes solver outcome, winning line existence, false-line result, or exactness within the horizon.
- `required_cell(state, cell, mechanism)`: true if the cell is needed by a declared micro-interaction, line of sight, range window, movement path, blocker relation, or payoff; verified by replay and ablation.
- `gains_time(red_action, state, limit)`: true if the Red action increases Blue's shortest proven mate length, consumes remaining slack, forces a detour, disables a required action, or pushes success past N.
- `real_pressure(red_feature, state)`: true if removing that pressure changes Blue's legal winning line, false line, Red response, exactness, or quality result.
- `position_gained(unit, cell, state)`: true only if the cell was previously unavailable or not useful, and becomes useful through cost, risk, ordering, removed blocker, Red threat, or verified trade-off.
- `prevents_micro_interaction(red_action, micro_id, state)`: true if the Red action invalidates preconditions, effect, timing, line, HP window, or required unit state for that micro-interaction.
- `non_decorative_micro(micro_id, scenario)`: true only if ablation changes winning line, false line, Red response, exactness, or fingerprint.

Anti-self-acquittal rule:

If the implementation cannot compute the property, it cannot use the word to justify acceptance. The candidate must be `unknown`, `draft`, or rejected until the property is measurable.

### Predicate And Schema Formalization

Before generator code starts, each computable semantic must have a short formal spec:

- stable name;
- input schema;
- output type;
- deterministic behavior;
- owning module;
- version/hash strategy;
- examples that return true;
- examples that return false;
- `unknown` behavior when required analysis is unavailable;
- fixture coverage;
- whether it can affect contract validation, solver proof, quality scoring, proof-domain inclusion, or promotion.

Minimum schemas to freeze before implementation:

- `ScenarioState`;
- `UnitState`;
- `Action`;
- `LegalMoveSet`;
- `MicroInteractionSpec`;
- `MechanismSpec`;
- `TacticalFingerprint`;
- `DefensiveDomainRule`;
- `DefensiveDomainDecision`;
- `PredicateResult`;
- `AblationResult`;
- `QualityFeatureSet`;
- `ProofCertificate`;
- `RejectionReason`;
- `GenerationDossier`.

Minimum predicates/features to freeze before implementation:

- `critical_blue_unit`;
- `required_cell`;
- `required_line`;
- `gains_time`;
- `real_pressure`;
- `position_gained`;
- `prevents_micro_interaction`;
- `non_decorative_micro`;
- `static_damage_clock`;
- `multi_unit_damage_clock`;
- `free_finisher_move`;
- `support_already_free`;
- `cosmetic_red_pressure`;
- `macro_template_signature`;
- `fingerprint_distinct`;
- `defensive_domain_inclusion`.
- `defensive_equivalence`.

No qualitative label may be introduced later without adding its predicate/schema entry first.

## Retro-Generator Model

The retro-generator starts from the final mate position. That is the puzzle exit, not the puzzle itself.

Its real job is to construct backward the mechanism that makes the exit reachable:

- which key must be created;
- which lock blocks it initially;
- which path reaches the key;
- which risk makes the sequence urgent;
- which natural alternatives fail.

### Anchor Choice

For each seed:

- choose a random Red Commandant cell from `A1-H2`;
- choose a random finisher from a controlled library;
- choose or receive a turn limit N from 3 to 10.

The Commandant position must remain valid after adding Rocks, Red units, and Blue units.

### Finisher Library

Each finisher is not merely a unit type. It is a formal schema:

- Blue unit type;
- attack range;
- expected damage against Commandant;
- legal final cells;
- line-of-sight requirements;
- final-turn movement requirements;
- minimum HP needed to survive;
- Red risks to avoid;
- compatible supports;
- compatible Rock patterns;
- compatible false-line patterns.

The first finisher library should be small and reliable. A few provable finishers are better than many fragile fragments.

Initial finisher families:

- ranged finisher: safe distance attack, useful for positional puzzles;
- melee finisher: high damage but precise access required;
- artillery finisher: constrained by lines and Rocks, useful for non-trivial puzzles.

The finisher is payoff, not mechanism. A scenario cannot be approved if the final hit is the only interesting fact.

### Mate-Position Construction

The generator first constructs the desired final state:

- Red Commandant HP at or below finisher damage;
- Blue finisher in a legal attack cell;
- Rocks that matter to line/cell/range decisions;
- Red blockers that prevent shortcuts;
- support units only if their role is explained by earlier micro-interactions.

This final state is validated immediately by the rules kernel.

### Backchain

Working backward from the mate-position:

1. choose a local micro-interaction compatible with the mate-position or partial state;
2. apply the minimum inverse transformation that makes the micro-interaction necessary;
3. modify cells, lines, HP, threats, or timing only if it creates a real tactical choice;
4. compute Red response through `Scenario Red Policy`, with no script;
5. simulate the fragment forward to verify the tactical relation exists;
6. repeat until a complete mechanism emerges and the initial state is valid.

Every inverse step must produce a transition that is legal when simulated forward.

The retro-generator must not invent a position and hope it works. It must keep a reproducible forward chain of verified micro-interactions, then ask the solver to prove that no shortcut or break exists.

## Micro-Interaction Library

The generator must not rely on macro-templates or complete prebuilt situations. It must rely on a library of tactical micro-interactions: small local patterns describing a single interesting relation between units, cells, lines, HP, threats, or timing.

A micro-interaction is not a scenario:

- it does not contain the global solution;
- it does not decide the whole sequence;
- it does not fix the complete move order;
- it does not guarantee that the puzzle exists by itself.

It is a tactical fragment, for example:

- a move that opens a line;
- a false trail that consumes time;
- a unit that can reach a key cell but becomes exposed;
- an attack that removes a blocker without occupying the cell;
- a Red threat on a necessary position;
- a choice between damaging the Commandant and preparing the mate;
- a natural action that ruins the mechanism.

Every micro-interaction declares:

- preconditions;
- effects;
- tactical tension;
- potential false line;
- compatibility constraints;
- rejection signals.

Anti-template rule:

A micro-interaction cannot contain the full solution order or fix a global sequence. If a pattern says "first do A, then B, then C and win", it is a disguised template and is forbidden. If it says "this move opens a line but creates risk", it is a valid ingredient.

Short formulation:

The generator must be a composer of tactical primitives, not a selector of solutions. Variety comes from dynamic combinations of parameterized and verified micro-interactions, not recycled macro-templates.

### Micro-Interaction Data Shape

```text
micro_interaction:
  id:
  involved_units:
  preconditions:
  tactical_effect:
  plausible_false_line:
  compatibility:
  reject_if:
```

### Valid Micro-Interaction Test

A micro-interaction is valid only if removing or replacing it changes at least one of:

- winning solution;
- documented false line;
- Red response computed by `Scenario Red Policy`;
- HP/range/line/timing exactness;
- tactical fingerprint.

This is a hard gate, not a report. If ablation changes nothing, the micro-interaction is decorative and the candidate is automatically rejected or simplified back to a state where the decorative micro-interaction is gone.

The tactical fingerprint is also a hard gate. It must be canonical, versioned, and reproducible from scenario data and computed predicates. If the fingerprint is missing, non-canonical, unversioned, or depends on narrative metadata that cannot be recomputed, the scenario cannot be `approved`.

### Position Gained

A position is **gained** only if it was previously unavailable or not useful, and becomes useful through at least one verified factor:

- time cost;
- risk of losing the unit;
- forced ordering;
- removed blocker;
- Red threat;
- trade-off between two real uses of the same unit;
- HP/line/range exactness that changes a false line.

If a unit simply walks to a free cell with no risk, decision cost, or transformation of the problem, that position is not gained. It is free movement.

### Conceptual Vocabulary

This is conceptual, not implementation. It is the initial vocabulary the generator may use to compose tactical puzzles.

Units considered:

- Commandant;
- Wingstalker;
- Crusher;
- Bastion;
- Cloudstriker;
- Earthstalker;
- Artillery;
- Rock.

Healer is excluded.

| ID | Unit / Relation | Tactical Effect | False Line Or Reject Signal |
| --- | --- | --- | --- |
| `LOS_OPEN_RANGED` | Cloudstriker, blocker, Rock | A unit removes or avoids a blocker and opens a Cloudstriker line. | Reject if the shot was already valid or the opening does not change mate. |
| `LOS_BLOCK_SELF_TRAP` | melee, blocker, Cloudstriker | A melee unit kills a blocker but occupies the wrong cell. | Natural move that blocks the finisher line. |
| `ARTILLERY_THROUGH_ROCK` | Artillery, Rock | Artillery can shoot through Rock while other units cannot. | Reject if removing Rock and ignoring it are equivalent. |
| `CLOUD_LOS_DENIAL` | Cloudstriker, Rock, blocker | Cloudstriker has range but no clean line. | Puzzle is discovering how to make the shot legal. |
| `MIN_RANGE_PRESSURE` | Cloudstriker or Artillery | Minimum range makes over-aggressive positioning bad. | Natural mistake: move too close and ruin the shot. |
| `FINISHER_CELL_GAIN` | finisher | Finisher must gain a specific cell. | Reject if final position is free from the start. |
| `SUPPORT_CELL_GAIN` | Blue support | Second damage source must gain position through a choice. | Prevents "two units just shoot". |
| `SUPPORT_FREE_IS_INVALID` | Blue support | Second source is already ready from the start. | Automatic reject: static damage clock. |
| `RED_ZONE_ON_KEY_CELL` | Red, key cell | Red controls a cell required by the solution. | Blue must enter, detour, or prepare. |
| `RED_ATTACKS_SUPPORT` | Red, Blue support | Red can damage or kill the unit preparing mate. | Reject if pressure does not change the sequence. |
| `RED_THREAT_BUT_NOT_ONLY` | Red, Blue unit | Red creates local threat but is not the only mechanism. | Reject if Red is decoration or a trivial single obstacle. |
| `COMMANDANT_DEFENSE_BAIT` | Commandant, melee | Moving adjacent to Commandant triggers strong defense/response. | Strong-looking move becomes false line. |
| `CRUSHER_BURST_MATE` | Crusher, Commandant | Crusher has high Commandant damage but must reach melee. | Powerful finisher, vulnerable to position and timing. |
| `CRUSHER_OVERCOMMIT_TRAP` | Crusher | Crusher can hit early but loses tempo/position. | False line: attack as soon as possible. |
| `BASTION_ANCHOR` | Bastion, key cell | Bastion occupies or protects a key cell. | Valid as shield/block, not as free damage. |
| `BASTION_WRONG_BLOCK` | Bastion, allied line | Bastion protects locally but blocks allied line. | Good local defense, bad global solution. |
| `EARTHSTALKER_CLEAR` | Earthstalker, non-flying | Earthstalker efficiently removes non-flying unit. | Valid only if it opens space or removes real guard. |
| `EARTHSTALKER_CAPTURE_BLOCK` | Earthstalker, melee target | Earthstalker kills melee and occupies target cell. | Can create accidental block. |
| `WINGSTALKER_REACH_KEY` | Wingstalker, key cell | Wingstalker flies to key cell ignoring obstacles. | Useful for pressure/trigger, not free main damage. |
| `WINGSTALKER_AIR_DUEL` | Wingstalker, flying | Wingstalker punishes flying units. | Can create false priority against Cloudstriker/Wingstalker. |
| `ROCK_AS_LOCK` | Rock, line/cell/range | Rock blocks line, cell, or range. | Reject if Rock is decoration. |
| `ROCK_AS_DECOY_BAD` | Rock | Attacking Rock looks useful but loses time. | False line only if tempo loss matters. |
| `WRONG_TARGET_TEMPO_LOSS` | Red unit or Rock | Attacking attractive target loses mate clock. | Valid only if not pure damage clock. |
| `ORDER_DEPENDENCY` | two local actions | Same actions in different order produce different state. | Strong pattern: order truly matters. |
| `CELL_VACATE_BEFORE_SHOT` | Blue unit, line/cell | Unit must vacate cell/line before shot. | Reject if shot remains legal anyway. |
| `OCCUPY_VS_CLEAR_CHOICE` | melee, blocker, critical cell | Killing a piece can clear or occupy a critical cell. | Hard choice between removal and position. |
| `DAMAGE_SETUP_NOT_CLOCK` | attacker, Commandant | Commandant damage matters only if it enables later mate. | Reject if it is repeated damage sum. |
| `HP_EXACT_WINDOW` | Commandant, attacker | HP is set so a false line leaves Commandant alive. | Exactness and false line become meaningful. |
| `RED_FORCES_TIMING` | Red, Blue unit/cell | Red threatens unit/cell and imposes order. | Reject if pressure does not change decisions. |
| `FORKED_ROLE_UNIT` | multi-role Blue unit | Unit can do two useful things, but only one preserves mate. | Good difficulty if both choices look natural. |

Correct composition example:

```text
LOS_OPEN_RANGED
+ OCCUPY_VS_CLEAR_CHOICE
+ RED_ATTACKS_SUPPORT
+ HP_EXACT_WINDOW
```

This is not a prebuilt sequence. These are local constraints the search tries to make compatible in the real state.

Automatic rejects:

- second unit shoots without gaining anything;
- Red threatens but does not change decisions;
- Rock is decoration;
- finisher is ready from the start;
- false lines are implausible;
- solution remains "accumulate damage on Commandant".

This library is vocabulary. The real generator must speak by combining these words, not reciting the same sentence.

## Sequence Composition

Each generated sequence must be represented as data, not only procedural code.

Conceptual example:

```text
Scenario N=3
Commandant: E1
Finisher: Cloudstriker shot from E4

Turn 1 micro: LOS_OPEN_RANGED
Turn 2 micro: FINISHER_CELL_GAIN + RED_ATTACKS_SUPPORT
Turn 3 final: finisher_kill_commandant
```

Each scenario must contain:

- one final finisher payoff;
- multiple compatible micro-interactions verified in the real state;
- Red response computed by the `Scenario Red Policy` after each non-terminal Blue turn;
- at least one plausible false line tied to a selected micro-interaction.

Initial density targets:

- N=3: at least 2 non-decorative preparatory micro-interactions plus finisher.
- N=4: at least 3 non-decorative preparatory micro-interactions plus finisher.
- N=10: many micro-interactions, only if still readable and non-decorative.

Each generated step must declare:

- micro-interaction id;
- Blue turn;
- involved Blue unit;
- tactical objective;
- required state before step;
- Blue action in winning line;
- Red response computed by policy;
- guaranteed state after Red response;
- connected false line;
- false-line failure condition;
- constraints on Rocks, lines, HP, and cells.

The sequence must also declare the solving mechanism as data:

- `lock`: what blocks mate in the initial position;
- `key`: what tactical resource must be created or activated;
- `path`: what steps make the key available;
- `risk`: what Red pressure or timing makes the sequence non-free;
- `decoy`: what natural choice looks good but breaks the mechanism;
- `payoff`: why the finisher works only after the mechanism.

## Density By Turn Count

The generator must not choose prebuilt profiles that already contain a solution. It chooses density profiles: how many micro-interactions to compose, how many units to place, how many false lines to verify, and how much Red pressure to require.

### N=3

Suggested structure:

- at least 2 non-decorative preparatory micro-interactions;
- 2-3 Blue units;
- 1-2 Red units besides Commandant;
- 1-2 certified false lines.

Healthy combinations:

- `DAMAGE_SETUP_NOT_CLOCK` + `FINISHER_CELL_GAIN`;
- `LOS_OPEN_RANGED` + `FINISHER_CELL_GAIN`;
- `RED_THREAT_BUT_NOT_ONLY` + `HP_EXACT_WINDOW`;
- `WRONG_TARGET_TEMPO_LOSS` + `OCCUPY_VS_CLEAR_CHOICE`.

### N=4-5

Suggested structure:

- 3-4 preparatory micro-interactions;
- 3-4 Blue units;
- 2-3 Red units besides Commandant;
- 2-3 certified false lines.

Healthy combinations:

- `LOS_OPEN_RANGED` + `DAMAGE_SETUP_NOT_CLOCK` + `FINISHER_CELL_GAIN`;
- `RED_ATTACKS_SUPPORT` + `RED_FORCES_TIMING` + `HP_EXACT_WINDOW`;
- `WRONG_TARGET_TEMPO_LOSS` + `CELL_VACATE_BEFORE_SHOT` + `FINISHER_CELL_GAIN`;
- `OCCUPY_VS_CLEAR_CHOICE` + `LOS_BLOCK_SELF_TRAP` + `FORKED_ROLE_UNIT` + `FINISHER_CELL_GAIN`.

### N=6-7

Suggested structure:

- 5-6 preparatory micro-interactions;
- 4-5 Blue units;
- 3-4 Red units besides Commandant;
- 3-5 certified false lines.

Healthy compositions:

- two groups of local micro-interactions that converge on the finale;
- `SUPPORT_CELL_GAIN` + `HP_EXACT_WINDOW` + `FINISHER_CELL_GAIN`;
- `RED_ATTACKS_SUPPORT` + `RED_FORCES_TIMING` + `ORDER_DEPENDENCY`;
- a long false line that reaches a live Commandant too late.

### N=8-10

Suggested structure:

- 7-9 preparatory micro-interactions;
- 5-7 Blue units;
- 4-6 Red units besides Commandant;
- 5+ certified false lines, only if solver can prove them.

Healthy compositions:

- multi-stage `DAMAGE_SETUP_NOT_CLOCK`, only if each threshold enables a different mechanism;
- chained `LOS_OPEN_RANGED`;
- `FINISHER_CELL_GAIN` with `RED_ZONE_ON_KEY_CELL` and `RED_ATTACKS_SUPPORT`;
- growing Red pressure through `RED_FORCES_TIMING`;
- main false line with `WRONG_TARGET_TEMPO_LOSS` that looks winning but fails on turn N+1.

N=8-10 should be special promotion material until solver and policy are mature.

## False Lines

False lines are not decorations. They are documented, plausible mistakes that we choose to explain and prove.

Exported false lines are not the full list of every wrong move a player can make. For all other deviations, the `Scenario Red Policy` must respond generally to the current state.

Useful categories:

- Blue attacks a non-essential Red unit and loses time;
- Blue moves finisher to wrong cell and loses line/range;
- Blue uses support too early;
- Blue destroys all Red units except Commandant and times out;
- Blue exposes a critical unit and Red kills it;
- Blue attacks a Rock/key cell and opens a better Red defense.

Each promoted false line must have proof: after that choice, with Red response computed by policy and/or required defensive domain, solver finds no win within the limit.

## Tools To Build From Scratch

### 1. Scenario Contract Schema

Formal data specification:

- board;
- coordinates;
- player ownership;
- unit types;
- HP;
- states such as `hasActed`;
- neutral Rocks;
- metadata;
- solving mechanism;
- tactical fingerprint;
- tactical unit roles;
- solution;
- false lines;
- seed.

Tests:

- accepts minimal valid scenario;
- rejects Blue Commandant;
- rejects Healer;
- rejects zero or multiple Red Commandants;
- rejects HP above max;
- rejects non-neutral Rocks;
- rejects Red Commandant outside `A1-H2`;
- rejects turn limit outside `3-10`;
- rejects scenario without declared solving mechanism;
- rejects scenario without tactical fingerprint.

### 2. Rules Kernel

Pure deterministic scenario-only simulator:

- initial state;
- legal move generation;
- action application;
- attacks;
- movement;
- line of sight;
- collisions;
- unit death;
- scenario victory/failure;
- Blue turn + Red response handling.

Tests:

- movement fixtures;
- attack fixtures;
- line-of-sight fixtures with Rocks;
- Commandant kill equals victory;
- no Blue units equals failure;
- timeout at start of Blue turn N+1;
- killing non-Commandant Red units does not cause victory.

### 3. Scenario Red Policy

Separate deterministic Red AI.

Objectives:

- credible to player;
- predictable for solver;
- stable over time;
- general over current state, not scripted over a sequence;
- only Red policy used at runtime in scenarios;
- never connected to standard AI.

Absolute rule:

The policy cannot contain per-scenario scripts, fixed-turn responses, hardcoded winning-line responses, or hand-authored branches for false lines. It must evaluate every reachable state through the same versioned decision rules.

The policy evaluates:

- immediate Commandant danger;
- ability to kill or damage critical Blue units;
- line blocking;
- Commandant protection/retreat if rules allow;
- focus fire;
- avoiding no-impact moves.

Decision recommendation:

- generate all legal Red moves;
- score them with versioned weights;
- use deterministic tie-break from seed and state;
- optionally return equivalent responses when solver must prove robustness over ties.

Tests:

- Red kills vulnerable Blue unit if it is best defense;
- Red blocks lethal line when possible;
- Red does not make pointless suicidal moves;
- same position + same seed gives same response;
- different seed changes only allowed tie-breaks;
- unexpected Blue deviations still receive credible responses;
- policy does not read scenario id, solution step, or response script.

### 4. Solver/Verifier

AND/OR search:

- Blue node: there exists a winning move.
- Red node: every response in proof domain must be survived.
- Depth: N scenario turns.
- Terminals: victory, timeout, no Blue units, no legal progress.

Minimum promotion proof:

- `Defensive proof` with versioned domain;
- `Runtime exactness proof` against `Scenario Red Policy`.

Best proof when tractable:

- `All-legal proof`.

Tests:

- mate in 1 fixture;
- mate in 3 with forced Red response;
- line against multiple Red defenses;
- `unknown` when Red domain cannot be explored safely;
- fixture where unconsidered Red defense breaks solution;
- passive Red move blocking key cell is included;
- Red attacking critical Blue is included/preferred over irrelevant Rock attack;
- proof reruns or candidate is rejected when policy chooses a different response;
- false `forced_win` from too narrow a Red domain is detected;
- timeout scenarios rejected;
- shortcuts rejected;
- principal variation emitted;
- false-line motivation emitted.

### 5. Finisher Library

Archive of allowed finishers.

Each finisher declares:

- type;
- damage;
- possible final cells relative to Commandant;
- possible previous cells;
- recommended supports;
- known risks;
- allowed Rock patterns;
- test fixtures.

Gate:

- each finisher generates at least one valid mate-position for supported Commandant cells;
- each finisher supports at least one certified line within 3-5 turns;
- no finisher generates illegal attack;
- unsupported `A1-H2` cells are explicitly blacklisted.

### 6. Micro-Interaction Library

Initial library of local tactical primitives, no macro-templates.

Gate:

- every micro-interaction declares preconditions, effects, tension, false line, compatibility, and rejection signals;
- every micro-interaction has local fixtures;
- no micro-interaction contains a global sequence;
- ablation of accepted micro-interaction changes puzzle or false line.

### 7. Retro-Generator Core

Responsibilities:

- receive seed and parameters;
- choose Commandant cell;
- choose finisher;
- choose mechanism family;
- choose lock, key, path, risk, and main false line;
- sample micro-interaction density profile;
- build mate-position;
- compose compatible micro-interactions in real state;
- backchain and forward-simulate each fragment;
- compute Red responses through `Scenario Red Policy`;
- declare false-line candidates;
- produce tactical fingerprint;
- produce scenario `candidate`;
- call verifier;
- discard uncertifiable candidates;
- export scenario and solution certificate.

Tests:

- fixed seed produces identical output;
- different seeds normally produce distinct tactical fingerprints;
- variations are not only coordinates, names, HP, or finisher;
- each accepted micro-interaction changes puzzle or false line;
- no micro-interaction contains full solution;
- Commandant always in `A1-H2`;
- finisher matches final attack;
- no Blue Commandant;
- Rocks always neutral;
- scenario respects turn limit;
- winning line replays in rules kernel;
- solver confirms solution;
- native variety metrics pass without history;
- novelty reject below maximum threshold.

### 8. Scenario Red Policy Credibility Harness

Automatic check of critical states against runtime policy.

Gate:

- policy answers critical states credibly;
- policy answers unexpected Blue deviations credibly;
- if policy diverges from assumed response, proof reruns;
- no per-scenario, per-turn, or winning-line script;
- no standard AI call.

### 9. Quality Evaluator

Decides whether a safe scenario is also good.

Quality rule:

An accepted scenario must contain multiple compatible micro-interactions that support one another. If removing a micro-pattern leaves the puzzle unchanged, it was decorative. If all micro-patterns only increase Commandant damage, the candidate is a damage clock.

A solution where multiple units repeatedly attack the Commandant without intermediate tactical transformation is static damage clock, even if it uses different units.

Minimum metrics:

- no immediate win;
- no trivial one-unit solution;
- no static damage clock;
- no multi-unit damage clock;
- finisher is not the only interesting fact;
- no already-ready support without gained position;
- at least one tactical mechanism activated;
- at least one verified false move;
- at least one plausible false move that blocks the mechanism;
- multiple compatible non-decorative micro-interactions;
- no disguised macro-template;
- fingerprint not reducible to coordinates or HP;
- fingerprint canonical, versioned, and recomputable;
- novelty check used only as safety net;
- real time pressure;
- Commandant not simply exposed;
- at least one positional decision;
- not too many equivalent winning first moves;
- Red response is credible;
- scenario does not depend on invisible behavior.

Tests:

- rejects immediate mate;
- rejects repeated damage;
- rejects multi-unit damage clock;
- rejects free finisher move-and-shoot;
- rejects support already in position;
- rejects cosmetic Red pressure;
- rejects scenario without declared mechanism;
- rejects pattern containing complete sequence;
- rejects decorative micro-interaction;
- rejects coordinate-only variants;
- rejects scenario without false moves;
- rejects too many winning first moves;
- approves controlled good fixture.

### 10. Solution Exporter

Generates readable out-of-game file.

Content:

- title;
- seed;
- N turns;
- Commandant cell;
- finisher;
- solving mechanism;
- tactical fingerprint;
- lock, key, path, risk, false trail, payoff;
- setup summary;
- turn-by-turn solution;
- Red response computed by `Scenario Red Policy`;
- why it works;
- false lines and why they fail;
- technical proof certificate;
- editorial notes.

Gate:

- exports complete winning line;
- exports at least one false line if declared;
- includes versions/hashes;
- never exports uncertified scenario as promoted.

### 11. Editor Import Adapter

Thin adapter that opens a certified scenario in the editor.

The editor must not become the generator. It only receives and displays result.

Tests:

- `New Scenario` starts internal generation;
- completion loads scenario in editor;
- generation error shows clear message;
- no feature exposed to final user;
- loaded scenario matches exported certificate.

### 12. Batch Runner And Promotion Pipeline

Offline batch produces many candidates.

Output per run:

- scenario;
- solution;
- proof certificate;
- quality report;
- rejection log;
- performance stats.

Manual promotion:

- batch produces candidates;
- we read solution and quality report;
- we test in editor;
- only then scenario enters final list.

Tests:

- batch can resume;
- seeds reproducible;
- reject logs readable;
- no uncertified candidate in approved folder.

## Performance Policy

Do not set rigid budgets before measuring certified generation cost.

Generation is a local internal tool. Performance is not the primary constraint. The primary constraint is useful result: a certified scenario or a diagnostic that improves the generator.

Practical rule:

- long processing is acceptable;
- offline batch of hours is acceptable;
- retry on derived seeds is acceptable;
- `not_generated` is acceptable for a single candidate;
- a run that consumes time without scenario, proof, or readable rejection reasons is not acceptable.

Initial calibration:

- 100 seeds for N=3;
- 100 seeds for N=4;
- 50 seeds for N=5;
- full success/reject/timing logs;
- at least 10 certified scenarios produced, even slowly.

Only after calibration do we optimize.

## Lua, C, And Hybrid

The target is not "write C". The target is an engine capable of retro-forward search, strict proof, cache, pruning, beam search, and dossier output.

These may be written in Lua if practical:

- State Engine;
- Legal Move Generator;
- apply/unapply;
- AND/OR solver;
- transposition table;
- pruning;
- beam search;
- constraint pre-check;
- mass simulation.

Lua is especially suitable for:

- contract;
- orchestration;
- export;
- quality report;
- editor adapter;
- promotion pipeline;
- calling `Scenario Red Policy`;
- final validation;
- fast prototyping;
- offline batch if timings remain acceptable.

C becomes appropriate when:

- Lua cannot explore enough states;
- legal move generation dominates runtime;
- apply/unapply and transposition table become bottleneck;
- solver returns too many `unknown` only due to compute limits;
- accelerating core concretely increases certified scenario production.

C is not mandatory. It is an investment only if it increases production of real scenarios.

Mandatory strategy:

1. freeze contract and fixtures;
2. implement the simplest form that can produce proofs;
3. measure real batches;
4. port only proven hot paths to C if useful;
5. keep stable Lua interface;
6. run same tests against Lua and C when both exist;
7. backend divergence produces `unknown` or `reject`, never `approve`.

## Non-Goals

- Do not modify standard AI.
- Do not use standard AI at runtime in scenarios.
- Do not use standard AI as generation/proof/certification oracle.
- Do not modify standard game rules.
- Do not generate scenarios for final users.
- Do not use Healer in scenario generation.
- Do not script `Scenario Red Policy` per scenario, solution, or turn.
- Do not define `Defensive proof` domain from desired winning line or convenient candidate response.
- Do not include generator, heavy solver, batch runner, or proof tooling in user package.
- Do not use ML/generative AI as solvability proof.
- Do not rely on random playtesting as certification.
- Do not rely on history as primary anti-repetition system.
- Do not consider a scenario new if only coordinates, names, HP, finisher, or Commandant position changed.
- Do not accept gameplay based only on Commandant damage accumulation.
- Do not use macro-templates or prebuilt complete scenarios.
- Do not accept micro-interactions that contain full solution order.
- Do not keep decorative micro-interactions.
- Do not promote scenario without solution file.
- Do not accept scenario only because it "looks good".

## Atomic Implementation Sequence

### Step -2: Computable Predicate And Schema Freeze

Output: formal predicate and schema specification for every qualitative term used by contract, solver, quality evaluator, defensive proof, and promotion.

Gate:

- every qualitative term used for acceptance/rejection has a computable predicate or schema field;
- each predicate declares inputs, output, deterministic behavior, owner module, version/hash, and `unknown` behavior;
- each predicate has at least one true fixture and one false fixture;
- each schema has validation rules and examples;
- `DefensiveDomainRule` uses only computable predicates over current state;
- quality evaluator has no narrative-only checks;
- proof certificate includes versions/hashes for predicates that affect certification;
- no generator, solver heuristic, or quality code starts before this gate passes.

### Step -1: Negative Fixtures From Failed System

Output: negative fixtures representing forbidden failure modes.

Gate:

- fixture with already-ready units repeatedly shooting Commandant;
- fixture with free finisher move-and-shoot;
- fixture with support already in position;
- fixture with cosmetic Red pressure;
- fixture with decorative Rock;
- fixture where novelty history rejects almost everything;
- fixture with micro-interactions always in same order;
- fixture with finisher library used as macro-template;
- fixture where unexpected Red defense breaks solution;
- fixture where passive Red move blocks key cell;
- fixture where Red can attack Rock or critical Blue unit, and critical Blue attack must enter domain;
- fixture where too-narrow Red domain creates false `forced_win`;
- all fixtures rejected by contract validator, quality evaluator, solver gate, or batch gate.

This step must precede the new generator. If the contract does not reject the failed system, it is not useful yet.

### Step 0: Freeze Contract

Output: contract document and schema including mechanism, fingerprint, dossier, and states `forced_win/unsolved/unknown/not_generated`.

Gate:

- contract validator tests pass;
- contract validator fails if any acceptance rule uses a qualitative concept missing from the frozen predicate/schema registry from Step -2;
- contract validator fails if any proof, quality, or promotion field references an unversioned predicate/schema;
- manual approval of contract.

### Step 1: Rules Reference And Fixtures

Output: scenario-only rules reference, initially Lua if useful, with atomic rule and parity fixtures.

Gate:

- movement/attack/LOS/victory/timeout tests;
- no UI or normal-game dependency.

### Step 2: State Engine + Legal Move Generator

Output: compact state, apply/unapply, legal move generation, canonical hash. Lua, C, or hybrid.

Gate:

- same states as reference;
- parity tests if multiple backends exist;
- divergence equals `unknown` or `reject`, never `approve`.

### Step 3: Scenario Red Policy V1

Output: deterministic credible policy.

Gate:

- response fixtures pass;
- deterministic tie-breaks;
- callable and cacheable harness;
- no standard AI modification.

### Step 4: Solver Proof V1

Output: AND/OR solver with transposition table, versioned defensive domain, principal variation, and refutations.

Gate:

- mate fixtures solved;
- multiple Red defenses considered;
- defensive domain deterministic and independent from winning line;
- every legal Red move receives a `DefensiveDomainDecision` with `include/exclude/unknown/fallback_all_legal` and reason codes;
- equivalence between Red moves is narrow, versioned, and fixture-tested;
- defensive domain version/hash included in proof certificate;
- false `forced_win` from too-narrow domain detected;
- timeout fixtures rejected;
- false lines proven.

### Step 5: Finisher Library V1

Output: 2-3 controlled finishers.

Gate:

- each finisher tested on supported Commandant cells;
- unsupported cells explicitly blacklisted.

### Step 6: Micro-Interaction Library V1

Output: initial tactical primitive library, no macro-templates.

Gate:

- every micro-interaction declares preconditions, effects, tension, false line, compatibility, and rejection signals;
- local fixtures for every micro-interaction;
- no micro-interaction contains global sequence;
- ablation of accepted micro-interaction changes puzzle or false line.

### Step 7: Retro-Generator Core V1

Output: retro-generator with constraint pre-check, beam search, fingerprint, and dossier.

Gate:

- at least 10 certified N=3 scenarios;
- distinct seeds normally produce distinct tactical problems;
- scenarios composed from micro-interactions, not macro-templates;
- native variety metrics pass without history;
- novelty reject below maximum threshold;
- solution exported;
- false moves verified.

### Step 8: Scenario Red Policy Credibility Harness

Output: automatic check of critical states against runtime policy.

Gate:

- credible response to critical states;
- credible response to unexpected Blue deviations;
- proof reruns if policy diverges;
- no per-scenario/turn/winning-line script;
- no standard AI call.

### Step 9: Quality Evaluator V1

Output: score and reject reasons.

Gate:

- rejects bad fixtures;
- rejects cosmetic variants;
- rejects static damage clock;
- rejects macro-template disguises;
- rejects decorative micro-interactions;
- approves controlled good fixture;
- no `approve` without certificate.

### Step 10: Batch Offline

Output: reproducible mass production.

Gate:

- resumable batch;
- timing and rejection report;
- clean approved folder.

### Step 11: Editor Adapter

Output: `New Scenario` loads generated candidate.

Gate:

- internal end-to-end test;
- editor scenario matches export;
- no exposure to final user.

### Step 12: Performance Calibration

Output: measured report.

Gate:

- defined seed runs;
- time per module;
- transposition table size;
- `accepted/not_generated/unknown/reject` rates.

### Step 13: Promotion Checklist

Required for each promoted scenario:

- scenario file;
- solution file;
- proof certificate;
- quality report;
- manual editor test;
- solution replay;
- at least one false-line verification.

## Final Success Criteria

The pipeline is ready when, given a seed, it produces a 3-10 turn scenario that:

- satisfies the contract;
- uses only qualitative claims backed by frozen computable predicates/schemas;
- uses Red Commandant in `A1-H2`;
- uses a declared finisher as payoff, not sole mechanism;
- is backchained from mate-position;
- composes local micro-interactions verified in real state;
- passes ablation tests for declared micro-interactions;
- automatically rejects decorative micro-interactions by hard gate;
- does not use macro-templates or prebuilt solutions;
- declares lock, key, path, risk, false trail, and payoff;
- emits non-cosmetic tactical fingerprint;
- emits canonical, versioned, recomputable tactical fingerprint;
- respects native variety metrics without relying on history;
- has a certain solution;
- has proven false lines;
- passes strict proof and exactness proof against `Scenario Red Policy`;
- returns full dossier for every accepted scenario;
- returns `not_generated` only for failed attempts, with useful diagnostics and retry path;
- is exportable and explainable;
- opens in editor;
- touches no standard AI or standard game behavior.
