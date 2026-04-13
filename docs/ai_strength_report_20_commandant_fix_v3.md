# AI Strength Self-Play Report

- Generated: 2026-02-12 17:40:14
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `8` (40.00%)
- Player 2 wins: `5` (25.00%)
- Draws: `7` (35.00%)
- Avg rounds: `44.50`
- Decision latency median (ms): `23.513`
- Decision latency p95 (ms): `106.842`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 11
- `no_interaction_limit`: 7
- `opponent_no_units_or_supply`: 2

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2141 | P1=1083 | P2=1058
- `attack`: total=919 | P1=462 | P2=457
- `supply_deploy`: total=408 | P1=205 | P2=203
- `repair`: total=54 | P1=20 | P2=34
- `skip`: total=5 | P1=3 | P2=2

## Unit Usecase Stats

- `Cloudstriker`: total=1196 | P1=621 | P2=575 | supply_deploy=79 | move=782 | attack=335
- `Artillery`: total=604 | P1=318 | P2=286 | supply_deploy=70 | move=321 | attack=213
- `Wingstalker`: total=406 | P1=197 | P2=209 | supply_deploy=64 | move=273 | attack=69
- `Crusher`: total=401 | P1=203 | P2=198 | supply_deploy=74 | move=237 | attack=90
- `Bastion`: total=330 | P1=161 | P2=169 | supply_deploy=32 | move=193 | attack=105
- `Earthstalker`: total=322 | P1=138 | P2=184 | supply_deploy=53 | move=202 | attack=67
- `Healer`: total=263 | P1=132 | P2=131 | supply_deploy=36 | move=133 | attack=40 | repair=54
- `SKIP_SLOT`: total=5 | P1=3 | P2=2 | skip=5

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=100.337ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=66 | replacements=0 | latency_p95=250.759ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=57.590ms
- Match 4 | seed=33013 | outcome=draw | rounds=28 | replacements=0 | latency_p95=103.163ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=65.647ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=143.630ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=70 | replacements=0 | latency_p95=103.456ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=35 | replacements=0 | latency_p95=53.025ms
- Match 9 | seed=72608 | outcome=draw | rounds=48 | replacements=0 | latency_p95=139.519ms
- Match 10 | seed=80527 | outcome=win(P1) | rounds=58 | replacements=0 | latency_p95=94.205ms
- Match 11 | seed=88446 | outcome=draw | rounds=26 | replacements=0 | latency_p95=174.922ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=71.883ms
- Match 13 | seed=104284 | outcome=draw | rounds=39 | replacements=0 | latency_p95=170.760ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=95.178ms
- Match 15 | seed=120122 | outcome=draw | rounds=50 | replacements=0 | latency_p95=114.944ms
- Match 16 | seed=128041 | outcome=draw | rounds=41 | replacements=0 | latency_p95=68.739ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=119.776ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=65.242ms
- Match 19 | seed=151798 | outcome=win(P1) | rounds=83 | replacements=0 | latency_p95=113.409ms
- Match 20 | seed=159717 | outcome=draw | rounds=56 | replacements=0 | latency_p95=92.303ms