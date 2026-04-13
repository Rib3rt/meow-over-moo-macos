# Steam Release Upload Checklist

Update: 2026-04-13
Status: Completed for current non-puzzle release baseline.

## 1. Steamworks backend
- [x] Achievements configured and published.
- [x] Leaderboard configured and published.
- [x] Steam backend configuration aligned with release build.

## 2. Code / build configuration
- [x] App configuration aligned with release target.
- [x] Test-only local artifacts isolated from release packaging.
- [x] Canonical release packaging flow validated.

## 3. Release package build
- [x] Release package generated successfully.
- [x] Validation report generated and reviewed.
- [x] Upload instructions generated and reviewed.

## 4. Pre-upload smoke pass
- [x] Steam launch + overlay validated.
- [x] Achievements and leaderboard validated.
- [x] Online + local multiplayer validated.
- [x] Steam Deck launch + controller flow validated.

## 5. Known issue policy
- [x] No release-blocking known issues remain for this baseline.
- [x] No open TODO items remain in release scope.

## 6. Store page readiness
- [x] Required store metadata finalized.
- [x] Required capsules and library assets uploaded.
- [x] Required screenshots/trailer readiness confirmed.

## 7. Depot upload
- [x] Correct content root and branch/depot mapping validated.
- [x] Post-upload Steam install validation completed.

## 8. Final launch validation
- [x] Core gameplay and online achievements validated.
- [x] Rating/leaderboard publication validated.
- [x] No blocking regressions detected.

## 9. Go / no-go
- [x] GO for the current release baseline.
