# UI Visual Language Audit (2026-03-05)

## Scope
- Main menu
- Faction select (`single/local/online host/online guest`)
- Online lobby
- Online leaderboard
- Gameplay HUD (`setup/deploy/turn/gameOver`)
- Confirm dialogs
- Game log viewer

## Canonical Theme Tokens
- Source of truth: `uiTheme.lua`
- Shared tokens:
  - `uiTheme.COLORS`
  - `uiTheme.TYPOGRAPHY`
  - `uiTheme.SPACING`
  - `uiTheme.PANEL`
  - `uiTheme.BUTTON_VARIANTS` (`default/success/danger/disabled`)
- Shared helpers:
  - `uiTheme.drawTechPanel`
  - `uiTheme.drawButton`
  - `uiTheme.applyButtonVariant`

## Screen Matrix
| Surface | Panel Style | Button Style | Disabled Style | Focus/Hover | Status |
|---|---|---|---|---|---|
| Main Menu | Shared theme panel | Shared default/disabled variants | Shared muted disabled | Shared hover/focus glow | Pass |
| Faction Select | Shared theme panel | Shared default/success/disabled variants | Color-only disabled start state | Hover/focus suppressed when disabled | Pass |
| Online Lobby | Shared theme panel | Shared default/disabled variants | Shared muted disabled | Shared keyboard + mouse focus model | Pass |
| Online Leaderboard | Shared theme panel | Shared default/disabled variants | Shared muted disabled | Shared keyboard + mouse focus model | Pass |
| Confirm Dialog | Shared theme panel | Shared default variant | N/A | Shared focus/hover behavior | Pass |
| Game Log Viewer | Shared theme panel | Shared default variant for Close | N/A | Shared hover/focus behavior | Pass |
| Gameplay HUD / Game Over | Uses `uiClass` theme bridge + shared base palette | Mixed (phase button custom draw path retained) | Existing behavior retained | Existing behavior retained | Partial (intentional) |

## Notes
- The previous disabled `"X"` overlay on online faction start button was removed. Disabled state is now color-only.
- `uiClass.lua` keeps gameplay-specific button rendering logic for phase contextual behavior; palette alignment is preserved but renderer is not fully replaced.
- This is a visual unification pass, not a gameplay logic pass.

## Regression Guards
- `scripts/ui_consistency_smoke.lua`
  - verifies shared tokens and helper usage in key UI modules.
- `scripts/steam_online_smoke.lua`
  - verifies invite receive flow and no-disabled-`X` overlay regression.
