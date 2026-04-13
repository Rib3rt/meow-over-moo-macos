# AI Strength Self-Play Report

- Generated: 2026-02-12 13:38:06
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `6` (30.00%)
- Player 2 wins: `8` (40.00%)
- Draws: `6` (30.00%)
- Avg rounds: `49.10`
- Decision latency median (ms): `11.649`
- Decision latency p95 (ms): `40.663`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 11
- `no_interaction_limit`: 6
- `opponent_no_units_or_supply`: 3

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2337 | P1=1189 | P2=1148
- `attack`: total=1041 | P1=535 | P2=506
- `supply_deploy`: total=416 | P1=209 | P2=207
- `repair`: total=84 | P1=14 | P2=70
- `skip`: total=26 | P1=14 | P2=12

## Unit Usecase Stats

- `Cloudstriker`: total=1078 | P1=563 | P2=515 | supply_deploy=77 | move=719 | attack=282
- `Crusher`: total=639 | P1=320 | P2=319 | supply_deploy=70 | move=393 | attack=176
- `Artillery`: total=596 | P1=320 | P2=276 | supply_deploy=72 | move=332 | attack=192
- `Bastion`: total=485 | P1=255 | P2=230 | supply_deploy=47 | move=266 | attack=172
- `Wingstalker`: total=387 | P1=216 | P2=171 | supply_deploy=59 | move=240 | attack=88
- `Earthstalker`: total=381 | P1=160 | P2=221 | supply_deploy=58 | move=237 | attack=86
- `Healer`: total=312 | P1=113 | P2=199 | supply_deploy=33 | move=150 | attack=45 | repair=84
- `SKIP_SLOT`: total=26 | P1=14 | P2=12 | skip=26

## Match Rows

- Match 1 | seed=9256 | outcome=draw | rounds=62 | replacements=0 | latency_p95=51.750ms
- Match 2 | seed=17175 | outcome=draw | rounds=37 | replacements=0 | latency_p95=52.258ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=80 | replacements=0 | latency_p95=22.710ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=80 | replacements=0 | latency_p95=41.795ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=99 | replacements=0 | latency_p95=33.609ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=63 | replacements=0 | latency_p95=47.975ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=74 | replacements=0 | latency_p95=37.590ms
- Match 8 | seed=64689 | outcome=win(P2) | rounds=63 | replacements=0 | latency_p95=32.252ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=22 | replacements=0 | latency_p95=40.854ms
- Match 10 | seed=80527 | outcome=draw | rounds=28 | replacements=0 | latency_p95=31.085ms
- Match 11 | seed=88446 | outcome=win(P2) | rounds=76 | replacements=0 | latency_p95=40.580ms
- Match 12 | seed=96365 | outcome=draw | rounds=52 | replacements=0 | latency_p95=41.081ms
- Match 13 | seed=104284 | outcome=win(P2) | rounds=73 | replacements=0 | latency_p95=57.789ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=35.646ms
- Match 15 | seed=120122 | outcome=draw | rounds=19 | replacements=0 | latency_p95=22.776ms
- Match 16 | seed=128041 | outcome=draw | rounds=23 | replacements=0 | latency_p95=26.529ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=40.397ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=64 | replacements=0 | latency_p95=24.117ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=24.305ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=34 | replacements=0 | latency_p95=18.249ms