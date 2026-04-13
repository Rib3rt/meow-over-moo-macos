# AI Strength Self-Play Report

- Generated: 2026-02-12 17:00:49
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `14` (70.00%)
- Player 2 wins: `1` (5.00%)
- Draws: `5` (25.00%)
- Avg rounds: `41.15`
- Decision latency median (ms): `23.667`
- Decision latency p95 (ms): `97.788`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 15
- `no_interaction_limit`: 5

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=1932 | P1=939 | P2=993
- `attack`: total=869 | P1=499 | P2=370
- `supply_deploy`: total=363 | P1=174 | P2=189
- `repair`: total=72 | P1=19 | P2=53
- `skip`: total=13 | P1=5 | P2=8

## Unit Usecase Stats

- `Cloudstriker`: total=1220 | P1=661 | P2=559 | supply_deploy=79 | move=752 | attack=389
- `Artillery`: total=477 | P1=255 | P2=222 | supply_deploy=75 | move=218 | attack=184
- `Wingstalker`: total=436 | P1=189 | P2=247 | supply_deploy=56 | move=301 | attack=79
- `Crusher`: total=369 | P1=190 | P2=179 | supply_deploy=52 | move=229 | attack=88
- `Earthstalker`: total=272 | P1=139 | P2=133 | supply_deploy=46 | move=175 | attack=51
- `Healer`: total=257 | P1=103 | P2=154 | supply_deploy=33 | move=121 | attack=31 | repair=72
- `Bastion`: total=205 | P1=94 | P2=111 | supply_deploy=22 | move=136 | attack=47
- `SKIP_SLOT`: total=13 | P1=5 | P2=8 | skip=13

## Match Rows

- Match 1 | seed=9256 | outcome=draw | rounds=41 | replacements=0 | latency_p95=88.203ms
- Match 2 | seed=17175 | outcome=draw | rounds=33 | replacements=0 | latency_p95=76.280ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=23 | replacements=0 | latency_p95=47.770ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=27 | replacements=0 | latency_p95=78.069ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=42 | replacements=0 | latency_p95=86.503ms
- Match 6 | seed=48851 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=72.678ms
- Match 7 | seed=56770 | outcome=win(P1) | rounds=59 | replacements=0 | latency_p95=94.907ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=39 | replacements=0 | latency_p95=73.023ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=83 | replacements=0 | latency_p95=117.961ms
- Match 10 | seed=80527 | outcome=win(P1) | rounds=35 | replacements=0 | latency_p95=88.025ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=179.606ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=24 | replacements=0 | latency_p95=119.269ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=32 | replacements=0 | latency_p95=114.310ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=79.361ms
- Match 15 | seed=120122 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=93.776ms
- Match 16 | seed=128041 | outcome=draw | rounds=63 | replacements=0 | latency_p95=79.347ms
- Match 17 | seed=135960 | outcome=draw | rounds=87 | replacements=0 | latency_p95=124.426ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=76 | replacements=0 | latency_p95=112.977ms
- Match 19 | seed=151798 | outcome=win(P1) | rounds=24 | replacements=0 | latency_p95=108.678ms
- Match 20 | seed=159717 | outcome=draw | rounds=31 | replacements=0 | latency_p95=54.497ms