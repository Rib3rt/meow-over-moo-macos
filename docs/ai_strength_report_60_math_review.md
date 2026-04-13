# AI Strength Self-Play Report

- Generated: 2026-02-18 20:33:32
- Matches: 60
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `28` (46.67%)
- Player 2 wins: `29` (48.33%)
- Draws: `3` (5.00%)
- Avg rounds: `56.57`
- Decision latency median (ms): `30.991`
- Decision latency p95 (ms): `121.130`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `opponent_no_units_or_supply`: 45
- `commandant_destroyed`: 12
- `no_interaction_limit`: 3

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=6710 | P1=3398 | P2=3312
- `attack`: total=4748 | P1=2371 | P2=2377
- `supply_deploy`: total=1553 | P1=773 | P2=780
- `skip`: total=244 | P1=122 | P2=122
- `repair`: total=227 | P1=107 | P2=120

## Unit Usecase Stats

- `Artillery`: total=2503 | P1=1239 | P2=1264 | supply_deploy=237 | move=1241 | attack=1025
- `Crusher`: total=2466 | P1=1271 | P2=1195 | supply_deploy=315 | move=1251 | attack=900
- `Cloudstriker`: total=2451 | P1=1238 | P2=1213 | supply_deploy=239 | move=1267 | attack=945
- `Bastion`: total=2087 | P1=1050 | P2=1037 | supply_deploy=222 | move=1017 | attack=848
- `Earthstalker`: total=1407 | P1=716 | P2=691 | supply_deploy=208 | move=764 | attack=435
- `Wingstalker`: total=1297 | P1=613 | P2=684 | supply_deploy=222 | move=698 | attack=377
- `Healer`: total=1027 | P1=522 | P2=505 | supply_deploy=110 | move=472 | attack=218 | repair=227
- `SKIP_SLOT`: total=244 | P1=122 | P2=122 | skip=244

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=62 | replacements=0 | latency_p95=133.563ms
- Match 2 | seed=17175 | outcome=win(P2) | rounds=60 | replacements=0 | latency_p95=105.280ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=37 | replacements=0 | latency_p95=131.217ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=68 | replacements=0 | latency_p95=138.900ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=143.371ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=32 | replacements=0 | latency_p95=128.367ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=59 | replacements=0 | latency_p95=177.864ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=56 | replacements=0 | latency_p95=94.263ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=65 | replacements=0 | latency_p95=149.775ms
- Match 10 | seed=80527 | outcome=win(P1) | rounds=55 | replacements=0 | latency_p95=123.434ms
- Match 11 | seed=88446 | outcome=win(P2) | rounds=71 | replacements=0 | latency_p95=121.521ms
- Match 12 | seed=96365 | outcome=draw | rounds=61 | replacements=0 | latency_p95=90.407ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=63 | replacements=0 | latency_p95=112.843ms
- Match 14 | seed=112203 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=123.273ms
- Match 15 | seed=120122 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=144.512ms
- Match 16 | seed=128041 | outcome=win(P1) | rounds=74 | replacements=0 | latency_p95=120.803ms
- Match 17 | seed=135960 | outcome=draw | rounds=14 | replacements=0 | latency_p95=259.171ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=58 | replacements=0 | latency_p95=94.748ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=35 | replacements=0 | latency_p95=106.234ms
- Match 20 | seed=159717 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=89.862ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=54 | replacements=0 | latency_p95=152.120ms
- Match 22 | seed=175555 | outcome=win(P1) | rounds=59 | replacements=0 | latency_p95=82.570ms
- Match 23 | seed=183474 | outcome=win(P2) | rounds=57 | replacements=0 | latency_p95=126.332ms
- Match 24 | seed=191393 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=105.367ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=84 | replacements=0 | latency_p95=135.347ms
- Match 26 | seed=207231 | outcome=win(P2) | rounds=65 | replacements=0 | latency_p95=107.902ms
- Match 27 | seed=215150 | outcome=win(P1) | rounds=51 | replacements=0 | latency_p95=108.998ms
- Match 28 | seed=223069 | outcome=win(P1) | rounds=68 | replacements=0 | latency_p95=125.672ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=59 | replacements=0 | latency_p95=98.349ms
- Match 30 | seed=238907 | outcome=win(P1) | rounds=57 | replacements=0 | latency_p95=145.287ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=62 | replacements=0 | latency_p95=94.424ms
- Match 32 | seed=254745 | outcome=win(P1) | rounds=54 | replacements=0 | latency_p95=101.041ms
- Match 33 | seed=262664 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=117.672ms
- Match 34 | seed=270583 | outcome=win(P2) | rounds=48 | replacements=0 | latency_p95=68.587ms
- Match 35 | seed=278502 | outcome=win(P2) | rounds=61 | replacements=0 | latency_p95=96.862ms
- Match 36 | seed=286421 | outcome=win(P2) | rounds=67 | replacements=0 | latency_p95=105.092ms
- Match 37 | seed=294340 | outcome=win(P2) | rounds=52 | replacements=0 | latency_p95=90.522ms
- Match 38 | seed=302259 | outcome=win(P2) | rounds=72 | replacements=0 | latency_p95=111.209ms
- Match 39 | seed=310178 | outcome=win(P1) | rounds=75 | replacements=0 | latency_p95=155.517ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=65 | replacements=0 | latency_p95=146.047ms
- Match 41 | seed=326016 | outcome=win(P1) | rounds=60 | replacements=0 | latency_p95=91.962ms
- Match 42 | seed=333935 | outcome=draw | rounds=59 | replacements=0 | latency_p95=119.137ms
- Match 43 | seed=341854 | outcome=win(P2) | rounds=64 | replacements=0 | latency_p95=82.406ms
- Match 44 | seed=349773 | outcome=win(P1) | rounds=37 | replacements=0 | latency_p95=170.770ms
- Match 45 | seed=357692 | outcome=win(P1) | rounds=66 | replacements=0 | latency_p95=126.132ms
- Match 46 | seed=365611 | outcome=win(P2) | rounds=73 | replacements=0 | latency_p95=88.658ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=66 | replacements=0 | latency_p95=175.940ms
- Match 48 | seed=381449 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=79.180ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=58 | replacements=0 | latency_p95=138.528ms
- Match 50 | seed=397287 | outcome=win(P2) | rounds=49 | replacements=0 | latency_p95=80.859ms
- Match 51 | seed=405206 | outcome=win(P2) | rounds=63 | replacements=0 | latency_p95=133.209ms
- Match 52 | seed=413125 | outcome=win(P2) | rounds=31 | replacements=0 | latency_p95=93.598ms
- Match 53 | seed=421044 | outcome=win(P2) | rounds=47 | replacements=0 | latency_p95=166.551ms
- Match 54 | seed=428963 | outcome=win(P2) | rounds=20 | replacements=0 | latency_p95=116.370ms
- Match 55 | seed=436882 | outcome=win(P2) | rounds=49 | replacements=0 | latency_p95=96.558ms
- Match 56 | seed=444801 | outcome=win(P1) | rounds=67 | replacements=0 | latency_p95=116.451ms
- Match 57 | seed=452720 | outcome=win(P2) | rounds=62 | replacements=0 | latency_p95=136.254ms
- Match 58 | seed=460639 | outcome=win(P1) | rounds=59 | replacements=0 | latency_p95=113.024ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=50 | replacements=0 | latency_p95=93.868ms
- Match 60 | seed=476477 | outcome=win(P1) | rounds=27 | replacements=0 | latency_p95=153.978ms