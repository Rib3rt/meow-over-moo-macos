# Steam Deck Hardware Checklist (Phase 1)

## Input Mapping Targets
- `A` / `LT` / `RT` / `Start`: Confirm
- `B` / `Back`: Cancel
- `DPad` + `Left Stick`: Navigation
- `Right Stick Up/Down`: Page Up / Page Down (log scrolling)
- `LB` / `RB`: Tab/Panel switching (outside modal log usage)

## Handheld Verification Steps
1. Boot game in Steam Deck handheld mode.
2. Main menu:
- Navigate all buttons with DPad/left stick.
- Confirm with `A`, `LT`, and `RT`.
- Cancel with `B`.
3. Faction select:
- Change selectors and start a game without using touchscreen.
- Verify `LT/RT` still confirm.
4. Gameplay:
- Select units and execute actions with controller.
- Open/close dialogs and confirm/cancel using triggers/buttons.
5. Game log viewer:
- Open viewer.
- Scroll with right stick vertical (page up/down behavior).
- Close with confirm/cancel.
6. Touch screen parity:
- Tap UI buttons and grid cells.
- Drag where scrolling is supported.
- Release interactions correctly.
- Confirm no duplicate touch clicks.

## Pass Criteria
- All critical flows are completable with controller only.
- `LT`/`RT` confirm everywhere `A` confirms.
- Right stick handles page scroll where supported.
- Touch behaves as single, consistent mouse-equivalent input.
