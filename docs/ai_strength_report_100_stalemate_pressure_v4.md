# AI Strength Self-Play Report

- Generated: 2026-02-12 15:36:50
- Matches: 100
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `48` (48.00%)
- Player 2 wins: `39` (39.00%)
- Draws: `13` (13.00%)
- Avg rounds: `32.04`
- Decision latency median (ms): `16.348`
- Decision latency p95 (ms): `76.302`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 82
- `no_interaction_limit`: 13
- `opponent_no_units_or_supply`: 5

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=7684 | P1=3871 | P2=3813
- `attack`: total=3322 | P1=1672 | P2=1650
- `supply_deploy`: total=1375 | P1=699 | P2=676
- `repair`: total=164 | P1=91 | P2=73
- `skip`: total=94 | P1=37 | P2=57

## Unit Usecase Stats

- `Cloudstriker`: total=4627 | P1=2337 | P2=2290 | supply_deploy=363 | move=3085 | attack=1179
- `Artillery`: total=2071 | P1=1067 | P2=1004 | supply_deploy=255 | move=1096 | attack=720
- `Crusher`: total=1565 | P1=793 | P2=772 | supply_deploy=204 | move=934 | attack=427
- `Wingstalker`: total=1195 | P1=532 | P2=663 | supply_deploy=177 | move=789 | attack=229
- `Earthstalker`: total=1193 | P1=638 | P2=555 | supply_deploy=165 | move=697 | attack=331
- `Healer`: total=984 | P1=518 | P2=466 | supply_deploy=115 | move=533 | attack=172 | repair=164
- `Bastion`: total=910 | P1=448 | P2=462 | supply_deploy=96 | move=550 | attack=264
- `SKIP_SLOT`: total=94 | P1=37 | P2=57 | skip=94

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=104.863ms
- Match 2 | seed=17175 | outcome=win(P2) | rounds=70 | replacements=0 | latency_p95=112.560ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=36.322ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=29.154ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=74 | replacements=0 | latency_p95=88.413ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=78 | replacements=0 | latency_p95=69.582ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=62.453ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=35.320ms
- Match 9 | seed=72608 | outcome=win(P2) | rounds=87 | replacements=0 | latency_p95=100.219ms
- Match 10 | seed=80527 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=64.307ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=58 | replacements=0 | latency_p95=77.922ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=53.489ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=103.627ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=77.823ms
- Match 15 | seed=120122 | outcome=win(P1) | rounds=84 | replacements=0 | latency_p95=91.881ms
- Match 16 | seed=128041 | outcome=draw | rounds=42 | replacements=0 | latency_p95=83.061ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=80.441ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=41 | replacements=0 | latency_p95=65.773ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=75.633ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=73 | replacements=0 | latency_p95=67.639ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=42.247ms
- Match 22 | seed=175555 | outcome=win(P1) | rounds=99 | replacements=0 | latency_p95=87.031ms
- Match 23 | seed=183474 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=27.600ms
- Match 24 | seed=191393 | outcome=draw | rounds=41 | replacements=0 | latency_p95=50.861ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=97.220ms
- Match 26 | seed=207231 | outcome=win(P2) | rounds=82 | replacements=0 | latency_p95=67.192ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=39 | replacements=0 | latency_p95=47.119ms
- Match 28 | seed=223069 | outcome=draw | rounds=51 | replacements=0 | latency_p95=85.351ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=59.456ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=55.071ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=37.682ms
- Match 32 | seed=254745 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=109.568ms
- Match 33 | seed=262664 | outcome=win(P2) | rounds=65 | replacements=0 | latency_p95=54.213ms
- Match 34 | seed=270583 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=44.394ms
- Match 35 | seed=278502 | outcome=win(P2) | rounds=92 | replacements=0 | latency_p95=97.702ms
- Match 36 | seed=286421 | outcome=draw | rounds=33 | replacements=0 | latency_p95=74.195ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=23 | replacements=0 | latency_p95=69.288ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=88.378ms
- Match 39 | seed=310178 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=82.145ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=50.445ms
- Match 41 | seed=326016 | outcome=win(P2) | rounds=25 | replacements=0 | latency_p95=50.591ms
- Match 42 | seed=333935 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=70.832ms
- Match 43 | seed=341854 | outcome=win(P1) | rounds=91 | replacements=0 | latency_p95=72.502ms
- Match 44 | seed=349773 | outcome=win(P1) | rounds=57 | replacements=0 | latency_p95=72.684ms
- Match 45 | seed=357692 | outcome=win(P2) | rounds=72 | replacements=0 | latency_p95=107.418ms
- Match 46 | seed=365611 | outcome=draw | rounds=38 | replacements=0 | latency_p95=72.004ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=89.494ms
- Match 48 | seed=381449 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=57.531ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=16 | replacements=0 | latency_p95=61.207ms
- Match 50 | seed=397287 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=25.346ms
- Match 51 | seed=405206 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=106.210ms
- Match 52 | seed=413125 | outcome=draw | rounds=51 | replacements=0 | latency_p95=45.540ms
- Match 53 | seed=421044 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=90.647ms
- Match 54 | seed=428963 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=65.829ms
- Match 55 | seed=436882 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=34.349ms
- Match 56 | seed=444801 | outcome=win(P1) | rounds=78 | replacements=0 | latency_p95=88.123ms
- Match 57 | seed=452720 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=51.977ms
- Match 58 | seed=460639 | outcome=draw | rounds=29 | replacements=0 | latency_p95=83.251ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=48.495ms
- Match 60 | seed=476477 | outcome=win(P1) | rounds=34 | replacements=0 | latency_p95=63.054ms
- Match 61 | seed=484396 | outcome=win(P1) | rounds=77 | replacements=0 | latency_p95=142.616ms
- Match 62 | seed=492315 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=131.196ms
- Match 63 | seed=500234 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=54.516ms
- Match 64 | seed=508153 | outcome=win(P2) | rounds=77 | replacements=0 | latency_p95=108.455ms
- Match 65 | seed=516072 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=35.702ms
- Match 66 | seed=523991 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=20.286ms
- Match 67 | seed=531910 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=57.474ms
- Match 68 | seed=539829 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=43.905ms
- Match 69 | seed=547748 | outcome=win(P1) | rounds=56 | replacements=0 | latency_p95=36.797ms
- Match 70 | seed=555667 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=58.613ms
- Match 71 | seed=563586 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=54.004ms
- Match 72 | seed=571505 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=68.011ms
- Match 73 | seed=579424 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=76.804ms
- Match 74 | seed=587343 | outcome=draw | rounds=24 | replacements=0 | latency_p95=78.514ms
- Match 75 | seed=595262 | outcome=draw | rounds=28 | replacements=0 | latency_p95=60.048ms
- Match 76 | seed=603181 | outcome=win(P1) | rounds=45 | replacements=0 | latency_p95=45.905ms
- Match 77 | seed=611100 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=58.150ms
- Match 78 | seed=619019 | outcome=win(P1) | rounds=39 | replacements=0 | latency_p95=49.257ms
- Match 79 | seed=626938 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=50.350ms
- Match 80 | seed=634857 | outcome=win(P1) | rounds=48 | replacements=0 | latency_p95=51.617ms
- Match 81 | seed=642776 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=57.704ms
- Match 82 | seed=650695 | outcome=win(P2) | rounds=72 | replacements=0 | latency_p95=64.136ms
- Match 83 | seed=658614 | outcome=win(P1) | rounds=5 | replacements=0 | latency_p95=41.486ms
- Match 84 | seed=666533 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=68.638ms
- Match 85 | seed=674452 | outcome=draw | rounds=35 | replacements=0 | latency_p95=75.722ms
- Match 86 | seed=682371 | outcome=win(P2) | rounds=30 | replacements=0 | latency_p95=55.008ms
- Match 87 | seed=690290 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=41.528ms
- Match 88 | seed=698209 | outcome=win(P2) | rounds=52 | replacements=0 | latency_p95=61.247ms
- Match 89 | seed=706128 | outcome=win(P1) | rounds=10 | replacements=0 | latency_p95=63.953ms
- Match 90 | seed=714047 | outcome=draw | rounds=47 | replacements=0 | latency_p95=43.544ms
- Match 91 | seed=721966 | outcome=draw | rounds=52 | replacements=0 | latency_p95=71.589ms
- Match 92 | seed=729885 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=82.063ms
- Match 93 | seed=737804 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=77.638ms
- Match 94 | seed=745723 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=96.217ms
- Match 95 | seed=753642 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=55.321ms
- Match 96 | seed=761561 | outcome=win(P1) | rounds=19 | replacements=0 | latency_p95=35.238ms
- Match 97 | seed=769480 | outcome=draw | rounds=17 | replacements=0 | latency_p95=96.959ms
- Match 98 | seed=777399 | outcome=win(P2) | rounds=67 | replacements=0 | latency_p95=69.191ms
- Match 99 | seed=785318 | outcome=win(P1) | rounds=21 | replacements=0 | latency_p95=39.582ms
- Match 100 | seed=793237 | outcome=win(P2) | rounds=11 | replacements=0 | latency_p95=39.250ms