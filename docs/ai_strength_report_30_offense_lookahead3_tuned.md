# AI Strength Self-Play Report

- Generated: 2026-02-12 14:11:45
- Matches: 30
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `11` (36.67%)
- Player 2 wins: `10` (33.33%)
- Draws: `9` (30.00%)
- Avg rounds: `28.77`
- Decision latency median (ms): `14.657`
- Decision latency p95 (ms): `74.689`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 20
- `no_interaction_limit`: 9
- `opponent_no_units_or_supply`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2051 | P1=1041 | P2=1010
- `attack`: total=902 | P1=455 | P2=447
- `supply_deploy`: total=401 | P1=204 | P2=197
- `repair`: total=49 | P1=18 | P2=31
- `skip`: total=1 | P1=1 | P2=0

## Unit Usecase Stats

- `Cloudstriker`: total=1441 | P1=678 | P2=763 | supply_deploy=110 | move=965 | attack=366
- `Artillery`: total=698 | P1=404 | P2=294 | supply_deploy=82 | move=359 | attack=257
- `Wingstalker`: total=370 | P1=173 | P2=197 | supply_deploy=66 | move=230 | attack=74
- `Healer`: total=311 | P1=147 | P2=164 | supply_deploy=35 | move=179 | attack=48 | repair=49
- `Crusher`: total=280 | P1=129 | P2=151 | supply_deploy=58 | move=162 | attack=60
- `Earthstalker`: total=188 | P1=112 | P2=76 | supply_deploy=38 | move=89 | attack=61
- `Bastion`: total=115 | P1=75 | P2=40 | supply_deploy=12 | move=67 | attack=36
- `SKIP_SLOT`: total=1 | P1=1 | P2=0 | skip=1

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=105.252ms
- Match 2 | seed=17175 | outcome=draw | rounds=32 | replacements=0 | latency_p95=57.603ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=37.150ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=29.458ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=41 | replacements=0 | latency_p95=67.269ms
- Match 6 | seed=48851 | outcome=draw | rounds=46 | replacements=0 | latency_p95=70.586ms
- Match 7 | seed=56770 | outcome=draw | rounds=43 | replacements=0 | latency_p95=63.233ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=35.619ms
- Match 9 | seed=72608 | outcome=draw | rounds=28 | replacements=0 | latency_p95=99.934ms
- Match 10 | seed=80527 | outcome=draw | rounds=44 | replacements=0 | latency_p95=70.529ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=38 | replacements=0 | latency_p95=60.494ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=44 | replacements=0 | latency_p95=91.451ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=103.821ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=77.451ms
- Match 15 | seed=120122 | outcome=draw | rounds=37 | replacements=0 | latency_p95=82.853ms
- Match 16 | seed=128041 | outcome=draw | rounds=37 | replacements=0 | latency_p95=67.311ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=62.496ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=37 | replacements=0 | latency_p95=68.714ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=77.671ms
- Match 20 | seed=159717 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=69.414ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=42.431ms
- Match 22 | seed=175555 | outcome=win(P1) | rounds=35 | replacements=0 | latency_p95=88.434ms
- Match 23 | seed=183474 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=28.112ms
- Match 24 | seed=191393 | outcome=draw | rounds=41 | replacements=0 | latency_p95=50.338ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=101.231ms
- Match 26 | seed=207231 | outcome=draw | rounds=32 | replacements=0 | latency_p95=86.030ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=39 | replacements=0 | latency_p95=49.115ms
- Match 28 | seed=223069 | outcome=win(P2) | rounds=75 | replacements=0 | latency_p95=112.895ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=61.434ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=58.025ms