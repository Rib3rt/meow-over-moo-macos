# AI Strength Self-Play Report

- Generated: 2026-02-20 11:00:11
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `base`
- Player 2 reference: `base`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `11` (55.00%)
- Player 2 wins: `9` (45.00%)
- Draws: `0` (0.00%)
- Avg rounds: `57.55`
- Decision latency median (ms): `77.484`
- Decision latency p95 (ms): `546.397`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `opponent_no_units_or_supply`: 13
- `commandant_destroyed`: 7

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2390 | P1=1191 | P2=1199
- `attack`: total=1497 | P1=770 | P2=727
- `supply_deploy`: total=557 | P1=278 | P2=279
- `repair`: total=82 | P1=34 | P2=48
- `skip`: total=46 | P1=24 | P2=22

## Unit Usecase Stats

- `Crusher`: total=979 | P1=479 | P2=500 | supply_deploy=120 | move=551 | attack=308
- `Artillery`: total=808 | P1=411 | P2=397 | supply_deploy=80 | move=401 | attack=327
- `Bastion`: total=690 | P1=340 | P2=350 | supply_deploy=80 | move=378 | attack=232
- `Cloudstriker`: total=647 | P1=329 | P2=318 | supply_deploy=80 | move=315 | attack=252
- `Earthstalker`: total=613 | P1=302 | P2=311 | supply_deploy=79 | move=343 | attack=191
- `Wingstalker`: total=518 | P1=288 | P2=230 | supply_deploy=80 | move=281 | attack=157
- `Healer`: total=271 | P1=124 | P2=147 | supply_deploy=38 | move=121 | attack=30 | repair=82
- `SKIP_SLOT`: total=46 | P1=24 | P2=22 | skip=46

## Match Rows

- Match 1 | seed=9256 | outcome=win(P1) | rounds=54 | replacements=0 | latency_p95=908.151ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=61 | replacements=0 | latency_p95=515.710ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=518.984ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=50 | replacements=0 | latency_p95=354.953ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=80 | replacements=0 | latency_p95=968.167ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=64 | replacements=0 | latency_p95=821.724ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=50 | replacements=0 | latency_p95=402.125ms
- Match 8 | seed=64689 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=461.048ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=66 | replacements=0 | latency_p95=538.139ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=47 | replacements=0 | latency_p95=544.884ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=54 | replacements=0 | latency_p95=511.698ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=51 | replacements=0 | latency_p95=536.849ms
- Match 13 | seed=104284 | outcome=win(P2) | rounds=65 | replacements=0 | latency_p95=505.039ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=54 | replacements=0 | latency_p95=406.986ms
- Match 15 | seed=120122 | outcome=win(P2) | rounds=58 | replacements=0 | latency_p95=915.489ms
- Match 16 | seed=128041 | outcome=win(P2) | rounds=68 | replacements=0 | latency_p95=653.980ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=67 | replacements=0 | latency_p95=477.896ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=60 | replacements=0 | latency_p95=751.478ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=47 | replacements=0 | latency_p95=360.939ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=47 | replacements=0 | latency_p95=625.377ms