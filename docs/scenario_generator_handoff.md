# Scenario Generator Handoff

Updated: 2026-05-06

## Market Release Alignment

- The market release line now ships Scenario Mode with 10 promoted manual puzzle scenarios (`P001` through `P010`).
- There is no separate non-puzzle / no-scenario release line.
- The generator remains internal tooling. It is not the release production path for the 2026-05-06 market build.
- The Scenario Editor remains hidden in the market build by `SETTINGS.FEATURES.SCENARIO_EDITOR = false`.

## Current Turning Point

The scenario generator track has moved from isolated archetypes toward verified composition, but it is not currently strong enough to be the release production path.

The current minimum acceptable scenario is no longer "a board that can be solved." It is a scenario built from multiple tactical interactions where each key Blue action has a proven consequence on the solution contract.

There are now two separate tracks:

- Market content track: manually curated Scenario Mode levels, playtested by the user, with focused scenario-only smoke tests before they remain in the public list.
- Generator/tooling track: internal verified composition tooling, still useful for predicates, schemas, Red Policy proof shape, negative fixtures, and future batch generation, but not currently trusted to produce release levels automatically.

Do not blur these tracks. A manual scenario may be added to the public list for playtest without claiming it is generator-certified. A generator candidate may pass tooling smoke without being release-worthy.

Public Scenario list:

- `P001` through `P010` are promoted market scenarios.
- `Scenario#20260505115547-384` was promoted as `P001`.
- `Scenario#20260505171632-565` was promoted as `P002`.
- `P003` is a manual curated scenario: N=3, dual neutral Rock locks on the Commandant file, Artillery acts as support by clearing the lower and upper locks across separate turns, and Cloudstriker remains the unique finisher on turn 3.
- Older exported scenarios and sidecars were removed from the LÖVE save-directory discovery path.
- Editor `New Scenario` currently exposes `support_intercepts_finisher_threat_artillery_finish` for manual playtest/import flow.
- The old manual P003 Crusher/contact candidate was discarded. Do not revive it as a variant; it was too fragile and produced side-lane compression problems.
- The old manual P003 Cloudstriker/Artillery line-break candidate was discarded. Its Red Wingstalker pressure was decorative: removing it did not change the winning contract, so the board was solvable but not tactically acceptable.

Current manual P003 playtest contract:

- Turn limit: 3 Blue turns.
- Main interaction: Artillery from `B5` moves to `B4` and destroys the lower Rock on `D4`.
- Support continuation: Artillery from `B4` moves to `B3` and destroys the upper Rock on `D3`.
- Payoff: Cloudstriker from `D8` moves to `D5` and destroys the damaged Commandant on `D2`.
- Current verification is focused but includes a binding-duration proof: `scripts/scenario_manual_candidate_smoke.lua` proves the material shape, initial lock state, solver-backed non-compression to two Blue turns under Red-pass bound, and the intended winning line under Scenario Red Policy.

The current verified composition floor is now a family of Scenario Mode profiles, not a single board:

- `composite_support_pressure_crusher_contact`
- `crusher_contact_breach`
- `support_reposition_rock_los_finish`
- `support_under_real_red_pressure`
- `support_intercepts_finisher_threat_artillery_finish`
- `dual_rock_lock_ranged_finish`

Every accepted profile must preserve these properties:

- separate tactical roles where the profile claims separate pressure, blocker, lock, or interceptor duties
- support is a role, not a hardcoded single unit; one or more non-finisher Blue units may provide support across different turns
- exactly one computable finisher may exist for the winning contract
- first Blue action is not a free obvious payoff
- the first Blue action must not merely be forced; there must be a plausible false path with computable failure evidence
- every key Blue action has an action-consequence proof
- N=3 must not be provably compressible into two turns, even under Red-pass bound
- Scenario Red Policy is deterministic and versioned
- standard AI is not used in scenario generation, proof, or runtime

This is now the floor, not the destination.

## Release Target

The 2026-05-06 market release target is 10 promoted Scenario Mode levels that are playable, publishable, and structurally different.

Do not optimize for quantity before structural quality.

Practical release plan has changed:

- Use manual curation first to build the release list under time pressure.
- Keep the generator as an internal research/tooling track until it can prove variety, false paths, and non-cloned batch selection.
- Each manual level should still get a small scenario-only smoke test that captures its tactical contract and the compression risks found during playtest.
- User playtest approval is the content gate. Tooling should support that gate, not pretend to replace it yet.

Long-term generator-backed production shape, after market release:

- build at least 5-8 distinct compositional profiles;
- generate certified variants for each profile;
- produce a larger pool of roughly 150-300 candidates;
- automatically reject weak, duplicate, obvious, or N-turn-compressible candidates;
- select a larger future expansion set only after certification quality is consistently high.

A final release scenario, whether manual or generator-backed, must:

- differ tactically, not only by translated coordinates;
- be playable with the shipped Scenario Red Policy;
- avoid standard AI completely;
- keep editor/generator/proof tooling internal;
- include the strongest practical evidence available for its track:
  - generator-backed scenarios require dossier, solver proof, false-line proof, quality, and action-consequence evidence;
  - manually curated scenarios require user approval plus focused scenario-only smoke coverage for material shape, intended line, runtime Red Policy behavior, and known compression risks;
- pass runtime smoke before publication.

## Non-Negotiable Guardrails

- Only Scenario Mode and scenario-generation tooling may change.
- Do not touch standard game behavior.
- Do not touch standard AI.
- Do not use standard AI for scenario proof, generation, runtime, oracle, or fallback.
- Do not expose generator, solver, batch, proof, or dossier tooling to final users.
- The scenario editor remains internal workflow; shipped scenario runtime remains separate.
- The shipped Scenario Red Policy is part of playable scenarios and must remain runtime-safe.
- Do not change scenario movement, phase timing, preview cells, commandant-defense timing, or turn handoff while working on generation.
- If a qualitative claim cannot be computed, it cannot approve a scenario.
- Unknown is acceptable. False certainty is not.
- Support coordination gates must allow multiple support actors over the scenario, but the final Commandant payoff must still be tied to one unique finisher.
- Intermediate Commandant damage is allowed only when it is a planned, non-trivial, contract-backed action and does not create or switch to a second finisher.

## Runtime Handoff Status

Scenario Mode turn timing is currently considered frozen runtime behavior.
Do not change it for generator/content work unless the user explicitly asks for a runtime fix.

Current Scenario turn flow:

- Blue has no Commandant phase.
- When Blue's two actions are complete, the handoff to Red should present immediately after real action resolution.
- The Blue->Red handoff must wait only for real unresolved action work:
  - movement in progress;
  - spawn/beam/ranged attack animation that still represents unresolved action state;
  - scheduled action-resolution callbacks explicitly tagged with `scenarioTurnHandoffBlocking`, such as beam/projection damage, melee kill capture, or Commandant-destruction evaluation.
- The Blue->Red handoff must not wait for residual particles, generic scheduled actions, or legacy visual effects.
- Red turn presentation happens before Commandant Defense.
- Commandant Defense uses Scenario timing with no silent start/tail delay, but keeps normal scan cadence.
- Scenario Red Policy starts only after Commandant Defense advances Red into `actions`.
- Standard AI remains completely outside Scenario Mode.

Known post-Commandant Defense timing:

- `scenarioRedVisibleDelaySec = 0`: no artificial delay before Scenario Red Policy computes its command.
- `scenarioRedPreviewDelaySec = 0.35`: after the command is selected, the runtime intentionally holds the preview for 0.35 seconds before executing it.
- The visible status currently remains `thinking` during that preview hold. If this feels like an AI pause, the preferred fix is presentation-only: show a preview/executing state once the command has already been selected, or deliberately lower the preview delay. Do not change Scenario Red Policy logic for this.

Regression guard:

- `scripts/scenario_turn_handoff_smoke.lua` must fail if Scenario handoff starts blocking on every scheduled action again.
- If the pause between Blue and Red returns, inspect `isScenarioTurnHandoffBlocked()`, `hasScenarioTurnHandoffBlockingScheduledActions()`, and `playGridClass:hasActiveScenarioTurnHandoffAnimations()` before touching any generator code.

## Implemented Scenario-Only Modules And Tests

Core scenario tooling exists under `scenario_tooling/`:

- schema/predicate freeze
- negative fixtures
- rules kernel
- state engine
- legal action generation through the state engine
- deterministic Scenario Red Policy adapter for tooling
- defensive domain
- solver and false-line proof
- finisher library
- micro-interaction library
- composition component library
- composition composer
- composition layout constraints and deterministic layout search
- quality evaluator
- retro generator
- batch/offline helpers

Runtime scenario policy exists separately:

- `scenarioRedPolicy.lua`
- `scenarioRedRuntime.lua`
- `scenarioRulesKernel.lua`
- `scenarioStateEngine.lua`

Important smoke tests:

- `scripts/scenario_composition_component_smoke.lua`
- `scripts/scenario_composition_composer_smoke.lua`
- `scripts/scenario_composition_layout_constraints_smoke.lua`
- `scripts/scenario_generator_step_minus_2_smoke.lua`
- `scripts/scenario_micro_interaction_smoke.lua`
- `scripts/scenario_rules_kernel_smoke.lua`
- `scripts/scenario_state_engine_smoke.lua`
- `scripts/scenario_solver_smoke.lua`
- `scripts/scenario_red_policy_smoke.lua`
- `scripts/scenario_red_policy_harness_smoke.lua`
- `scripts/scenario_quality_evaluator_smoke.lua`
- `scripts/scenario_profile5_hardening_smoke.lua`
- `scripts/scenario_action_consequence_replay_smoke.lua`
- `scripts/scenario_retro_generator_smoke.lua`
- `scripts/scenario_composite_generator_smoke.lua`
- `scripts/scenario_export_import_smoke.lua`
- `scripts/scenario_manual_candidate_smoke.lua`
- `scripts/scenario_turn_handoff_smoke.lua`
- `scripts/ui_consistency_smoke.lua`

Latest verified gate results:

- `lua scripts/scenario_composition_component_smoke.lua` passed 6/6.
- `lua scripts/scenario_micro_interaction_smoke.lua` passed 8/8.
- `lua scripts/scenario_composition_composer_smoke.lua` passed 16/16.
- `lua scripts/scenario_composition_layout_constraints_smoke.lua` passed 13/13.
- `lua scripts/scenario_generator_step_minus_2_smoke.lua` passed 14/14.
- `lua scripts/scenario_composite_generator_smoke.lua` passed 3/3.
- `lua scripts/scenario_retro_generator_smoke.lua` passed 13/13.
- `lua scripts/scenario_quality_evaluator_smoke.lua` passed 9/9.
- `lua scripts/scenario_profile5_hardening_smoke.lua` passed 4/4.
- `lua scripts/scenario_action_consequence_replay_smoke.lua` passed 6/6.
- `lua scripts/scenario_batch_offline_smoke.lua` passed 6/6.
- `lua scripts/scenario_manual_candidate_smoke.lua` passed 4/4 for the current P003 dual-lock candidate.
- `lua scripts/scenario_export_import_smoke.lua` passed 10/10.
- `lua scripts/scenario_red_policy_smoke.lua` passed 14/14.
- `lua scripts/scenario_red_policy_harness_smoke.lua` passed 6/6.
- `lua scripts/scenario_solver_smoke.lua` passed 11/11.
- `lua scripts/scenario_state_engine_smoke.lua` passed 9/9.
- `lua scripts/scenario_turn_handoff_smoke.lua` passed 7/7.
- `lua scripts/ui_consistency_smoke.lua` passed 63/63.
- `lua scripts/input_smoke.lua` passed 13/13.
- `luac -p` passed on the modified validation, composition, generator, evaluator, fixture, and smoke files.

## Current Composition Profiles

The generator now emits `compositionalContract.actionConsequences` for composition-profile candidates.

Contracts are built through `scenario_tooling/composition_composer.lua` using profiles:

- `composite_support_pressure_crusher_contact`
- `crusher_contact_breach`
- `support_reposition_rock_los_finish`
- `support_under_real_red_pressure`
- `support_intercepts_finisher_threat_artillery_finish`
- `dual_rock_lock_ranged_finish`

The primary composite profile expands components from `scenario_tooling/composition_component_library.lua`:

- `support_pressure_answer`
- `contact_blocker_clear`
- `finisher_staging_gain`
- `exact_contact_payoff`
- `wrong_target_tempo_branch`

The `crusher_contact_breach` profile reuses:

- `contact_blocker_clear`
- `finisher_staging_gain`
- `exact_contact_payoff`
- `wrong_target_tempo_branch`

The `support_reposition_rock_los_finish` profile uses:

- `rock_lock_conversion`
- `los_open_ranged_lane`
- `finisher_staging_gain`
- `exact_contact_payoff`
- `wrong_target_tempo_branch`

The `support_under_real_red_pressure` profile uses:

- `support_pressure_answer`
- `rock_lock_conversion`
- `los_open_ranged_lane`
- `finisher_staging_gain`
- `exact_contact_payoff`
- `wrong_target_tempo_branch`

The `support_intercepts_finisher_threat_artillery_finish` profile uses:

- `finisher_interceptor_clear`
- `finisher_staging_gain`
- `exact_contact_payoff`
- `wrong_target_tempo_branch`

The `dual_rock_lock_ranged_finish` profile uses:

- `dual_rock_lock_chain`
- `los_open_ranged_lane`
- `exact_contact_payoff`
- `wrong_target_tempo_branch`

The composer owns consequence slots for these profiles.
For `composite_support_pressure_crusher_contact`:

- `support_setup_move`
- `support_blocker_clear_attack`
- `finisher_staging_move`
- `crusher_contact_move`
- `commandant_payoff_attack`

For `crusher_contact_breach`:

- `support_contact_setup_move`
- `support_blocker_clear_attack`
- `finisher_staging_move`
- `crusher_contact_move`
- `commandant_payoff_attack`

For `support_reposition_rock_los_finish`:

- `support_los_setup_move`
- `support_rock_clear_attack`
- `finisher_staging_move`
- `finisher_los_cell_move`
- `commandant_payoff_attack`

For `support_under_real_red_pressure`:

- `support_pressure_setup_move`
- `support_rock_clear_attack`
- `finisher_staging_move`
- `finisher_los_cell_move`
- `commandant_payoff_attack`

For `support_intercepts_finisher_threat_artillery_finish`:

- `support_interceptor_setup_move`
- `support_interceptor_clear_attack`
- `artillery_staging_move`
- `artillery_final_cell_move`
- `commandant_payoff_attack`

For `dual_rock_lock_ranged_finish`:

- `support_lower_lock_setup_move`
- `support_lower_rock_clear_attack`
- `support_upper_lock_setup_move`
- `support_upper_rock_clear_attack`
- `finisher_dual_lock_cell_move`
- `commandant_payoff_attack`

`retro_generator.lua` now passes slot ids plus state/evidence into the composer. It no longer owns the micro/component mapping for those action consequences.

The visible baseline geometry now comes from `scenario_tooling/composition_layout_constraints.lua`.
The baseline is guarded by exact state hash `c55d3d64`, tactical fingerprint hash `9860c24e`, roster/cell assertions, and key-action destination assertions.
The layout module can enumerate deterministic translated candidates; the generator can use that search only behind internal tooling flag `enableLayoutSearch`.
The default generated scenario remains the baseline.

Each key consequence is represented as an `AblationResult`-shaped record with:

- action index or action signature
- canonical action
- micro-interaction id
- component id
- proven status
- changed output evidence
- before/after state hash
- predicate evidence

The current composite support-pressure profile proves consequences for:

- support setup move
- support blocker-clear attack
- Crusher staging move
- Crusher contact move
- final Commandant payoff attack

The `crusher_contact_breach` profile proves the same action-consequence shape without Red support pressure.
It is guarded as a valid composition profile, not as the final target difficulty.

The `support_reposition_rock_los_finish` profile proves a structurally different ROCK/LOS line:

- support gains the Rock-clear key cell;
- support converts the Rock lock;
- finisher stages;
- finisher reaches the opened ranged line cell;
- finisher makes the final Commandant payoff attack.

The `support_under_real_red_pressure` profile promotes the support-pressure path into a real composition profile:

- support must move into a key cell while Red pressure is real;
- skipping the setup lets the deterministic Scenario Red Policy remove the support unit;
- support converts the Rock lock after repositioning;
- finisher stages, then reaches the opened ranged line cell;
- finisher makes the final Commandant payoff attack.

The `support_intercepts_finisher_threat_artillery_finish` profile adds a new structural family:

- the pressure target is the fragile Artillery finisher, not the support;
- the support is a Bastion that must reposition before clearing the interceptor;
- skipping the support setup lets deterministic Scenario Red Policy remove the Artillery threat;
- Artillery then needs a staging cell and a final firing cell before the payoff;
- the profile proves N=3 is not compressible to two turns even with Red passing.

The `dual_rock_lock_ranged_finish` profile adds a double-lock ranged family:

- two distinct Rocks block the Cloudstriker line;
- one support must convert the lower lock, then the upper lock across separate turns;
- each support move/attack has a separate action-consequence record;
- Cloudstriker only receives a meaningful final cell after both locks are removed;
- the profile passes quality evaluator approval and proves N=3 is not compressible to two turns.

The certificate now rejects composition candidates that lack proven action consequence evidence. The Step -2 validation gate and quality evaluator both reject composition dossiers missing or weakening compositional evidence for registered composition profiles.

## Why This Matters

The earlier weak direction was archetype-shaped: one block of handcrafted layout produced something solvable, but the tactical explanation was not yet enforceable.

The new direction is composition-shaped:

- interactions are independent tactical parts;
- every part must have computable preconditions;
- every part must produce a consequence;
- every consequence must change winning line, false line, Red response, exactness, legal move set, or outcome;
- a scenario is accepted only when the composition is proven, not merely described.

This is the foundation for harder multi-turn scenarios.

## Known Gaps

- Manual release curation is now the active delivery path. The generator is not yet the source of release-ready level quantity.
- P003 is a public-list playtest candidate. It has targeted runtime-policy smoke coverage plus solver-backed N=3 non-compression under Red-pass bound, but user playtest remains the content gate.
- The current composite board cells, required cells, critical Blue unit ids, and deterministic translated layouts now live in `composition_layout_constraints.lua`.
- `retro_generator.lua` still assembles `ScenarioState` unit records and performs the proof walk.
- Component metadata now lives in the component library, and the contract is built through the composer.
- The composer is profile-driven and owns consequence slots; the layout module owns baseline geometry and simple translated search candidates.
- Component compatibility is not yet declared in data.
- Component-level negative fixtures are complete for the current composite profile, `crusher_contact_breach`, ROCK/LOS component/profile failures, `support_under_real_red_pressure`, `support_intercepts_finisher_threat_artillery_finish`, and `dual_rock_lock_ranged_finish`; every new profile must add its own persistent failure fixtures.
- The current `AblationResult` records are action-consequence proofs, but the system still needs stronger generic ablation replay for arbitrary component removal.
- New scenario variety is still limited until new component profiles are added and layout-search output is broadened beyond one certified translated variant.
- Release variety is currently 6 profiles out of the required 5-8. This clears the minimum family count, but release batch selection should remain blocked until profile variants are demonstrably non-cloned and the pool/selection tooling can rank 150-300 certified candidates.
- Editor `New Scenario` is not the current release production mechanism. It is still useful for internal experiments and should not be assumed to output publishable levels.

## Next Objectives, Atomic

1. Add `scenario_tooling/composition_component_library.lua`.
2. Define the `CompositionComponentSpec` shape in code comments and smoke tests.
3. Add component spec `support_pressure_answer`.
4. Add component spec `contact_blocker_clear`.
5. Add component spec `finisher_staging_gain`.
6. Add component spec `exact_contact_payoff`.
7. Add component spec `wrong_target_tempo_branch`.
8. Add `scripts/scenario_composition_component_smoke.lua`.
9. Test that every component declares id, version, family, units, preconditions, produced micros, required predicates, consequence outputs, ablation subject, and incompatibilities.
10. Test that component specs are not macro templates.
11. Test that component specs do not contain full solution lines or scripted Red replies.
12. Add a composer module `scenario_tooling/composition_composer.lua`.
13. Make the composer accept a seed and a component profile.
14. Make the composer assemble the existing composite from component specs instead of inline archetype assumptions.
15. Keep the visible output of `composite_support_pressure_crusher_contact` stable during the migration.
16. Move composite component metadata out of `retro_generator.lua` and into the component library.
17. Keep `retro_generator.lua` as orchestrator/certifier, not component data owner.
18. Add a smoke proving the migrated composite still certifies and approves.
19. Add a smoke proving removal of any required component rejects the dossier.
20. Add a smoke proving every key Blue action maps to exactly one component consequence.
21. Add a negative fixture for "component listed but no action consequence."
22. Add a negative fixture for "component consequence exists but changed output is empty."
23. Add a negative fixture for "component uses same Red unit as pressure and blocker."
24. Add a negative fixture for "first move is obvious attack on pressure/blocker."
25. Add a negative fixture for "component order is scripted macro-template."
26. Add a second valid composition profile after the migration is green.
27. Prefer combining existing primitives before inventing new units or runtime behavior.
28. Add new micro-interactions only when a composition needs a distinct computable consequence.
29. Run scenario-only smoke tests after each component/composer step.
30. Run `scripts/ui_consistency_smoke.lua` only as an isolation guard; do not modify UI/runtime to satisfy generation work.

Completed from this list:

- 1 through 13 are implemented.
- 14 is implemented for the compositional contract/profile/slot layer; board geometry is still generated by `retro_generator.lua`.
- 15 is preserved by current smoke tests.
- 16 is implemented for component/consequence-slot mapping; geometric construction still remains in `retro_generator.lua`.
- 18 through 20 are implemented as composer/composite smoke gates:
  - empty action consequences reject;
  - duplicate key-action consequence coverage rejects;
  - missing key-action consequence coverage rejects;
  - required component without proven coverage rejects;
  - required component removed from contract rejects.
- 21 through 25 are implemented as persistent negative fixtures and quality-evaluator gates:
  - component listed without action consequence rejects;
  - component consequence with empty changed outputs rejects;
  - same Red unit used as pressure and blocker rejects;
  - obvious first attack on pressure/blocker rejects;
  - scripted component-order macro-template rejects.
- Profile-driven layout constraints are implemented for the current composite profile:
  - baseline geometry is emitted by `composition_layout_constraints.lua`;
  - default generated scenario hash remains `c55d3d64`;
  - a controlled translated layout with column offset `+1` certifies under the same proof gates;
  - out-of-bounds translated layouts reject at the constraint layer.
- Gated layout-search selection is implemented behind internal flag `enableLayoutSearch`:
  - default New Scenario output is unchanged;
  - generator diagnostics record layout candidates and attempts;
  - batch smoke proves baseline plus `colOffset=+1` can both certify as distinct geometries.
- 26 is implemented with the second valid composition profile `crusher_contact_breach`:
  - composer profile and consequence slots exist;
  - layout constraints exist;
  - generator emits a valid compositional contract and five action consequences;
  - quality evaluator requires and validates the contract;
  - persistent profile-specific negative fixtures exist;
  - retro smoke proves the profile is not compressible to two turns.
- ROCK/LOS component and profile gate is implemented:
  - `rock_lock_conversion` and `los_open_ranged_lane` component specs exist;
  - decorative Rock and already-open LOS fixture failures are persistent;
  - `support_reposition_rock_los_finish` composer profile and layout constraints exist;
  - generator emits a valid compositional contract and five action consequences;
  - quality evaluator requires and validates the contract;
  - retro smoke proves the profile is not compressible to two turns.
- 27 remains the active design rule: combine existing primitives before inventing runtime behavior.
- Profile 4 is implemented with `support_under_real_red_pressure`:
  - composer profile and consequence slots exist;
  - left/right layout constraints exist with `red_support_threat` separate from the false-target decoy;
  - generator emits a valid compositional contract and five action consequences;
  - Step -2 validation gate rejects missing/invalid compositional contracts;
  - quality evaluator requires and validates the contract;
  - persistent profile-specific negative fixtures exist for missing action consequences, empty changed outputs, cosmetic pressure, free removable pressure, decorative Rock, and already-open LOS;
  - retro smoke proves the profile is policy-driven and not compressible to two turns.
- Profile 5 is implemented with `support_intercepts_finisher_threat_artillery_finish`:
  - composer profile and consequence slots exist;
  - baseline layout constraints exist for the Bastion support, fragile Artillery finisher, and Earthstalker interceptor;
  - generator alias `interceptor_artillery` emits a valid compositional contract and five action consequences;
  - Step -2 validation gate and quality evaluator require and validate the contract;
  - persistent profile-specific negative fixtures exist for missing action consequences, empty changed outputs, cosmetic interceptor pressure, freely removable pressure, decorative interceptor, and free final firing cell;
  - retro smoke proves the profile is policy-driven and not compressible to two turns.
- Profile 5 hardening is implemented:
  - scripted-opponent-line negative fixture rejects as `macro_template_signature`;
  - quality evaluator approval is asserted for `interceptor_artillery`;
  - action-consequence hashes replay against the intended line;
  - 10 seed checks prove `interceptor_artillery` is not compressible to two turns.
- Profile 6 is implemented with `dual_rock_lock_ranged_finish`:
  - component `dual_rock_lock_chain` exists;
  - composer profile and six consequence slots exist;
  - baseline layout constraints exist for lower Rock, upper Rock, support lower/upper key cells, Cloudstriker final cell, and Commandant payoff;
  - generator alias `dual_rock_lock` emits a certified compositional dossier;
  - quality evaluator approves the generated dossier and Scenario Red Policy harness passes;
  - persistent profile-specific negative fixtures exist for missing action consequences, empty changed outputs, decorative upper lock, already-open lane, and scripted macro-template;
  - retro smoke proves the profile is not compressible to two turns.
- Generic action-consequence replay hardening is implemented:
  - all six compositional profiles are generated and replayed from their `compositionalContract.intendedLine`;
  - every key Blue action must be legal at replay time;
  - every key Blue action consequence must match the replayed action;
  - before/after state hashes in `delta_metrics` must match recomputed state hashes;
  - declared changed outputs must have at least local replay evidence.

Next immediate objective:

- Continue manual release curation with fresh scenarios, not coordinate clones of the existing public puzzles.
- For each new manual candidate, write or extend `scripts/scenario_manual_candidate_smoke.lua` with:
  - material/shape assertions;
  - initial free-damage/free-finisher rejection;
  - at least one likely compression or false-line check from playtest;
  - intended winning line replay through Scenario Red Policy and Commandant Defense.
- Keep P003 under user playtest. If the user rejects it, discard it rather than layering patches.
- Do not touch runtime timing, movement, previews, or Scenario Red Policy behavior for manual content work.
- Keep batch release selection disabled until profile variety and certified variant diversity are strong enough for a 150-300 candidate pool.
- Generator-side profile 7-8 work is postponed unless the user explicitly returns to generator research.

## Immediate Next Implementation Choice

Implement manual P004 planning and test harness extension first.

Do not change runtime timing, movement, previews, or Scenario Red Policy behavior.

The correct next delivery is still not a 50-level batch. It is the next user-testable, structurally distinct manual Scenario Mode level with a focused smoke test and a clear solution/false-line note.

Generator research can resume later with profile 7 planning and component gap analysis, but that is no longer the active release path.

## Handoff Rule For Future Agents

Before implementing, read:

- `docs/retro_generator_greenfield_plan.md`
- `docs/scenario_mode_isolation_rule.md`
- this file

Then run or inspect:

- `scripts/scenario_composite_generator_smoke.lua`
- `scripts/scenario_retro_generator_smoke.lua`
- `scripts/scenario_quality_evaluator_smoke.lua`

If a proposed change touches non-scenario gameplay, standard AI, runtime phase timing, movement timing, preview timing, or Commandant Defense timing, stop and re-scope.
