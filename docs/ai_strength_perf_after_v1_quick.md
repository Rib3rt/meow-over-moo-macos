# AI Strength Self-Play Report

- Generated: 2026-02-20 18:18:53
- Matches: 5
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `base`
- Player 2 reference: `base`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `5` (100.00%)
- Player 2 wins: `0` (0.00%)
- Draws: `0` (0.00%)
- Avg rounds: `55.00`
- Decision latency median (ms): `71.553`
- Decision latency p95 (ms): `596.720`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `opponent_no_units_or_supply`: 4
- `commandant_destroyed`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=532 | P1=267 | P2=265
- `attack`: total=383 | P1=207 | P2=176
- `supply_deploy`: total=138 | P1=68 | P2=70
- `repair`: total=22 | P1=3 | P2=19
- `skip`: total=11 | P1=1 | P2=10

## Unit Usecase Stats

- `Artillery`: total=254 | P1=132 | P2=122 | supply_deploy=20 | move=98 | attack=136
- `Crusher`: total=252 | P1=153 | P2=99 | supply_deploy=30 | move=137 | attack=85
- `Cloudstriker`: total=157 | P1=71 | P2=86 | supply_deploy=20 | move=81 | attack=56
- `Bastion`: total=126 | P1=56 | P2=70 | supply_deploy=20 | move=72 | attack=34
- `Earthstalker`: total=121 | P1=62 | P2=59 | supply_deploy=19 | move=66 | attack=36
- `Wingstalker`: total=98 | P1=48 | P2=50 | supply_deploy=20 | move=49 | attack=29
- `Healer`: total=67 | P1=23 | P2=44 | supply_deploy=9 | move=29 | attack=7 | repair=22
- `SKIP_SLOT`: total=11 | P1=1 | P2=10 | skip=11

## Match Rows

- Match 1 | seed=9256 | outcome=win(P1) | rounds=46 | replacements=0 | latency_p95=743.141ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=61 | replacements=0 | latency_p95=575.471ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=567.109ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=60 | replacements=0 | latency_p95=496.610ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=55 | replacements=0 | latency_p95=782.596ms