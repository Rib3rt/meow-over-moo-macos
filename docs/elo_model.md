# MeowOverMoo Online Rating Model

## Current Model (Implemented)

Algorithm:
- Glicko-2
- one completed online match = one rating period

Persistent local profile:
- stored in `OnlineRatingProfile.dat`
- intended to be Steam Cloud-compatible if the app enables Cloud sync

Public leaderboard source:
- `SETTINGS.RATING.LEADERBOARD_NAME` (default `global_glicko2_v1`)
- uploaded score is the rounded public rating value

Default state:
- `rating = 1200`
- `RD = 350`
- `volatility = 0.06`
- `tau = 0.5`

Clamp bounds:
- `MIN_RATING = 100`
- `MAX_RATING = 5000`
- `MIN_RD = 40`
- `MAX_RD = 350`

Per-player profile fields:
- `rating`
- `rd`
- `vol`
- `games`
- `lastPeriodDay`
- `lastOpponentHash`
- `sameOpponentStreak`
- `lastRankedDay`

Prematch synchronization:
- each side loads its local Glicko-2 profile before match start
- profiles are exchanged over prematch lockstep handshake
- host freezes a shared `ratingContext` into `MATCH_START`
- both clients update from the same frozen snapshot after result resolution

Result handling:
- win/loss: rated unless disabled by policy
- draw: rated when `SETTINGS.RATING.UPDATE_ON_DRAW == true`
- timeout forfeit: rated when `SETTINGS.RATING.UPDATE_ON_TIMEOUT_FORFEIT == true`
- desync abort: unrated when `SETTINGS.RATING.UPDATE_ON_DESYNC_ABORT == false`
- aborted/no-winner paths: unrated

Rematch guard:
- first 2 consecutive ranked matches vs the same opponent inside 24h: rated
- 3rd+ consecutive match vs the same opponent inside 24h: unrated
- playing a different opponent resets the streak immediately
- 24h timeout also resets the streak

Why this design:
- stronger uncertainty handling than classic Elo
- no external backend required
- deterministic post-match update from shared prematch snapshot
- simple Steam-only anti-farming rule without full pair-history service

## Production Limits

This is still not authoritative ranked infrastructure.

Known limits:
- no trusted server-side validation of match result
- no tamper-proof pair-history enforcement
- profile persistence depends on local save data (and Steam Cloud if enabled for the app)
- repeated-opponent protection is intentionally simple, not exhaustive

For a fully authoritative ranked system, use a backend/service and treat Steam leaderboard as display only.
