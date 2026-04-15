# Scenario Mode Isolation Rule

This repository currently treats scenario mode as an isolated feature track.

## Hard Rule

Every scenario-related change must be scenario-only.

- Do not modify baseline behavior of other modes.
- Gate scenario behavior with `GAME.MODE.SCENARIO`.
- Keep scenario UI and flow changes inside scenario-specific states/screens when possible.

## Applies To

- Gameplay rules (win/lose conditions, turn flow, auto-pass behavior)
- UI (buttons, modal content, focus behavior, sounds)
- Data flow (scenario snapshot load, attempts counter, scenario result handling)
- Scenario editor interactions (unit edit constraints, simulate pre-checks, editor-only dialogs/sounds)
- Packaging/release toggles for scenario-enabled variants

## Safety Check Before Merge

- Confirm all new branches are gated by `GAME.MODE.SCENARIO` (or scenario state module path).
- Run smoke checks for non-scenario modes (`scripts/ui_consistency_smoke.lua`, `scripts/input_smoke.lua`).
- If non-scenario behavior changed, treat as regression and revert or re-scope.
