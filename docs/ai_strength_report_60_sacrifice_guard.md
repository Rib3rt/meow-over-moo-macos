# AI Strength Self-Play Report

- Generated: 2026-02-12 16:09:40
- Matches: 60
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `27` (45.00%)
- Player 2 wins: `22` (36.67%)
- Draws: `11` (18.33%)
- Avg rounds: `33.20`
- Decision latency median (ms): `17.365`
- Decision latency p95 (ms): `81.056`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 48
- `no_interaction_limit`: 11
- `opponent_no_units_or_supply`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=4893 | P1=2473 | P2=2420
- `attack`: total=2010 | P1=1007 | P2=1003
- `supply_deploy`: total=860 | P1=434 | P2=426
- `repair`: total=93 | P1=45 | P2=48
- `skip`: total=19 | P1=8 | P2=11

## Unit Usecase Stats

- `Cloudstriker`: total=2954 | P1=1452 | P2=1502 | supply_deploy=223 | move=1957 | attack=774
- `Artillery`: total=1247 | P1=671 | P2=576 | supply_deploy=164 | move=654 | attack=429
- `Crusher`: total=946 | P1=515 | P2=431 | supply_deploy=131 | move=596 | attack=219
- `Wingstalker`: total=736 | P1=384 | P2=352 | supply_deploy=111 | move=483 | attack=142
- `Earthstalker`: total=712 | P1=363 | P2=349 | supply_deploy=99 | move=442 | attack=171
- `Bastion`: total=639 | P1=253 | P2=386 | supply_deploy=57 | move=417 | attack=165
- `Healer`: total=622 | P1=321 | P2=301 | supply_deploy=75 | move=344 | attack=110 | repair=93
- `SKIP_SLOT`: total=19 | P1=8 | P2=11 | skip=19

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=110.519ms
- Match 2 | seed=17175 | outcome=win(P2) | rounds=40 | replacements=0 | latency_p95=72.243ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=36.900ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=29.695ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=38 | replacements=0 | latency_p95=90.216ms
- Match 6 | seed=48851 | outcome=win(P1) | rounds=94 | replacements=0 | latency_p95=72.234ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=63.407ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=35.860ms
- Match 9 | seed=72608 | outcome=win(P2) | rounds=78 | replacements=0 | latency_p95=127.118ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=62 | replacements=0 | latency_p95=69.100ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=77 | replacements=0 | latency_p95=67.661ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=53.628ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=105.872ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=77.846ms
- Match 15 | seed=120122 | outcome=win(P2) | rounds=109 | replacements=0 | latency_p95=99.973ms
- Match 16 | seed=128041 | outcome=win(P1) | rounds=77 | replacements=0 | latency_p95=83.572ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=81.444ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=41 | replacements=0 | latency_p95=65.843ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=77.600ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=37.667ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=42.631ms
- Match 22 | seed=175555 | outcome=draw | rounds=76 | replacements=0 | latency_p95=84.786ms
- Match 23 | seed=183474 | outcome=win(P1) | rounds=28 | replacements=0 | latency_p95=39.625ms
- Match 24 | seed=191393 | outcome=win(P1) | rounds=40 | replacements=0 | latency_p95=65.298ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=102.129ms
- Match 26 | seed=207231 | outcome=draw | rounds=53 | replacements=0 | latency_p95=69.708ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=38 | replacements=0 | latency_p95=59.834ms
- Match 28 | seed=223069 | outcome=win(P2) | rounds=70 | replacements=0 | latency_p95=89.079ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=61.428ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=57.143ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=38.479ms
- Match 32 | seed=254745 | outcome=win(P2) | rounds=36 | replacements=0 | latency_p95=97.158ms
- Match 33 | seed=262664 | outcome=draw | rounds=37 | replacements=0 | latency_p95=55.670ms
- Match 34 | seed=270583 | outcome=win(P1) | rounds=19 | replacements=0 | latency_p95=48.012ms
- Match 35 | seed=278502 | outcome=draw | rounds=47 | replacements=0 | latency_p95=116.864ms
- Match 36 | seed=286421 | outcome=draw | rounds=51 | replacements=0 | latency_p95=74.440ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=23 | replacements=0 | latency_p95=72.587ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=91.826ms
- Match 39 | seed=310178 | outcome=draw | rounds=41 | replacements=0 | latency_p95=85.225ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=52.733ms
- Match 41 | seed=326016 | outcome=win(P2) | rounds=25 | replacements=0 | latency_p95=52.344ms
- Match 42 | seed=333935 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=73.647ms
- Match 43 | seed=341854 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=67.908ms
- Match 44 | seed=349773 | outcome=win(P2) | rounds=83 | replacements=0 | latency_p95=77.357ms
- Match 45 | seed=357692 | outcome=draw | rounds=25 | replacements=0 | latency_p95=231.218ms
- Match 46 | seed=365611 | outcome=draw | rounds=38 | replacements=0 | latency_p95=74.858ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=91.927ms
- Match 48 | seed=381449 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=59.355ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=73.922ms
- Match 50 | seed=397287 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=25.774ms
- Match 51 | seed=405206 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=97.609ms
- Match 52 | seed=413125 | outcome=draw | rounds=51 | replacements=0 | latency_p95=39.496ms
- Match 53 | seed=421044 | outcome=win(P2) | rounds=22 | replacements=0 | latency_p95=45.076ms
- Match 54 | seed=428963 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=53.542ms
- Match 55 | seed=436882 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=31.869ms
- Match 56 | seed=444801 | outcome=win(P1) | rounds=88 | replacements=0 | latency_p95=97.812ms
- Match 57 | seed=452720 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=53.131ms
- Match 58 | seed=460639 | outcome=draw | rounds=29 | replacements=0 | latency_p95=87.532ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=51.047ms
- Match 60 | seed=476477 | outcome=draw | rounds=55 | replacements=0 | latency_p95=71.858ms