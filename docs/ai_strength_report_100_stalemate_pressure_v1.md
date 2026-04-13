# AI Strength Self-Play Report

- Generated: 2026-02-12 15:06:30
- Matches: 100
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `45` (45.00%)
- Player 2 wins: `35` (35.00%)
- Draws: `20` (20.00%)
- Avg rounds: `30.18`
- Decision latency median (ms): `15.191`
- Decision latency p95 (ms): `71.460`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 79
- `no_interaction_limit`: 20
- `opponent_no_units_or_supply`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=7218 | P1=3647 | P2=3571
- `attack`: total=3133 | P1=1607 | P2=1526
- `supply_deploy`: total=1338 | P1=679 | P2=659
- `repair`: total=157 | P1=58 | P2=99
- `skip`: total=57 | P1=12 | P2=45

## Unit Usecase Stats

- `Cloudstriker`: total=4649 | P1=2305 | P2=2344 | supply_deploy=363 | move=3100 | attack=1186
- `Artillery`: total=2007 | P1=1051 | P2=956 | supply_deploy=254 | move=1046 | attack=707
- `Crusher`: total=1396 | P1=691 | P2=705 | supply_deploy=199 | move=816 | attack=381
- `Wingstalker`: total=1132 | P1=521 | P2=611 | supply_deploy=174 | move=733 | attack=225
- `Earthstalker`: total=999 | P1=532 | P2=467 | supply_deploy=155 | move=611 | attack=233
- `Healer`: total=922 | P1=455 | P2=467 | supply_deploy=112 | move=485 | attack=168 | repair=157
- `Bastion`: total=741 | P1=436 | P2=305 | supply_deploy=81 | move=427 | attack=233
- `SKIP_SLOT`: total=57 | P1=12 | P2=45 | skip=57

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=103.349ms
- Match 2 | seed=17175 | outcome=draw | rounds=32 | replacements=0 | latency_p95=57.106ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=36.251ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=29.126ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=35 | replacements=0 | latency_p95=69.387ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=66 | replacements=0 | latency_p95=79.971ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=83 | replacements=0 | latency_p95=62.682ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=34.009ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=91 | replacements=0 | latency_p95=85.512ms
- Match 10 | seed=80527 | outcome=draw | rounds=42 | replacements=0 | latency_p95=64.852ms
- Match 11 | seed=88446 | outcome=draw | rounds=40 | replacements=0 | latency_p95=63.177ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=52.637ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=103.887ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=75.976ms
- Match 15 | seed=120122 | outcome=draw | rounds=24 | replacements=0 | latency_p95=99.514ms
- Match 16 | seed=128041 | outcome=draw | rounds=56 | replacements=0 | latency_p95=66.791ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=66.051ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=37 | replacements=0 | latency_p95=71.004ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=76.569ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=41 | replacements=0 | latency_p95=52.102ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=42.175ms
- Match 22 | seed=175555 | outcome=win(P1) | rounds=40 | replacements=0 | latency_p95=91.303ms
- Match 23 | seed=183474 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=27.793ms
- Match 24 | seed=191393 | outcome=draw | rounds=41 | replacements=0 | latency_p95=53.686ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=100.562ms
- Match 26 | seed=207231 | outcome=draw | rounds=65 | replacements=0 | latency_p95=59.529ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=39 | replacements=0 | latency_p95=47.871ms
- Match 28 | seed=223069 | outcome=draw | rounds=47 | replacements=0 | latency_p95=83.680ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=60.943ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=56.845ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=38.794ms
- Match 32 | seed=254745 | outcome=win(P1) | rounds=22 | replacements=0 | latency_p95=114.080ms
- Match 33 | seed=262664 | outcome=draw | rounds=23 | replacements=0 | latency_p95=74.851ms
- Match 34 | seed=270583 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=45.990ms
- Match 35 | seed=278502 | outcome=win(P2) | rounds=75 | replacements=0 | latency_p95=94.341ms
- Match 36 | seed=286421 | outcome=draw | rounds=75 | replacements=0 | latency_p95=79.039ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=76.580ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=91.350ms
- Match 39 | seed=310178 | outcome=win(P1) | rounds=24 | replacements=0 | latency_p95=83.999ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=52.791ms
- Match 41 | seed=326016 | outcome=win(P1) | rounds=82 | replacements=0 | latency_p95=52.420ms
- Match 42 | seed=333935 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=73.075ms
- Match 43 | seed=341854 | outcome=draw | rounds=37 | replacements=0 | latency_p95=65.665ms
- Match 44 | seed=349773 | outcome=draw | rounds=37 | replacements=0 | latency_p95=95.363ms
- Match 45 | seed=357692 | outcome=win(P2) | rounds=54 | replacements=0 | latency_p95=75.834ms
- Match 46 | seed=365611 | outcome=win(P1) | rounds=85 | replacements=0 | latency_p95=69.518ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=91.003ms
- Match 48 | seed=381449 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=59.481ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=16 | replacements=0 | latency_p95=63.370ms
- Match 50 | seed=397287 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=25.608ms
- Match 51 | seed=405206 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=98.189ms
- Match 52 | seed=413125 | outcome=win(P1) | rounds=61 | replacements=0 | latency_p95=39.617ms
- Match 53 | seed=421044 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=76.681ms
- Match 54 | seed=428963 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=53.473ms
- Match 55 | seed=436882 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=31.366ms
- Match 56 | seed=444801 | outcome=draw | rounds=74 | replacements=0 | latency_p95=88.972ms
- Match 57 | seed=452720 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=53.635ms
- Match 58 | seed=460639 | outcome=draw | rounds=29 | replacements=0 | latency_p95=83.546ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=51.402ms
- Match 60 | seed=476477 | outcome=win(P1) | rounds=45 | replacements=0 | latency_p95=68.544ms
- Match 61 | seed=484396 | outcome=draw | rounds=51 | replacements=0 | latency_p95=64.127ms
- Match 62 | seed=492315 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=138.517ms
- Match 63 | seed=500234 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=59.262ms
- Match 64 | seed=508153 | outcome=win(P1) | rounds=99 | replacements=0 | latency_p95=87.481ms
- Match 65 | seed=516072 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=37.249ms
- Match 66 | seed=523991 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=21.798ms
- Match 67 | seed=531910 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=59.581ms
- Match 68 | seed=539829 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=46.504ms
- Match 69 | seed=547748 | outcome=win(P1) | rounds=63 | replacements=0 | latency_p95=46.796ms
- Match 70 | seed=555667 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=60.497ms
- Match 71 | seed=563586 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=56.380ms
- Match 72 | seed=571505 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=69.788ms
- Match 73 | seed=579424 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=78.461ms
- Match 74 | seed=587343 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=86.577ms
- Match 75 | seed=595262 | outcome=draw | rounds=30 | replacements=0 | latency_p95=61.858ms
- Match 76 | seed=603181 | outcome=win(P1) | rounds=45 | replacements=0 | latency_p95=47.695ms
- Match 77 | seed=611100 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=59.700ms
- Match 78 | seed=619019 | outcome=draw | rounds=57 | replacements=0 | latency_p95=58.676ms
- Match 79 | seed=626938 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=53.339ms
- Match 80 | seed=634857 | outcome=win(P1) | rounds=48 | replacements=0 | latency_p95=53.392ms
- Match 81 | seed=642776 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=59.096ms
- Match 82 | seed=650695 | outcome=win(P1) | rounds=78 | replacements=0 | latency_p95=75.652ms
- Match 83 | seed=658614 | outcome=win(P1) | rounds=5 | replacements=0 | latency_p95=41.726ms
- Match 84 | seed=666533 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=71.577ms
- Match 85 | seed=674452 | outcome=win(P2) | rounds=27 | replacements=0 | latency_p95=88.564ms
- Match 86 | seed=682371 | outcome=win(P2) | rounds=30 | replacements=0 | latency_p95=56.839ms
- Match 87 | seed=690290 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=43.462ms
- Match 88 | seed=698209 | outcome=draw | rounds=58 | replacements=0 | latency_p95=64.719ms
- Match 89 | seed=706128 | outcome=win(P1) | rounds=10 | replacements=0 | latency_p95=66.418ms
- Match 90 | seed=714047 | outcome=draw | rounds=47 | replacements=0 | latency_p95=48.318ms
- Match 91 | seed=721966 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=81.589ms
- Match 92 | seed=729885 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=83.891ms
- Match 93 | seed=737804 | outcome=win(P2) | rounds=60 | replacements=0 | latency_p95=84.264ms
- Match 94 | seed=745723 | outcome=win(P1) | rounds=26 | replacements=0 | latency_p95=80.405ms
- Match 95 | seed=753642 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=57.681ms
- Match 96 | seed=761561 | outcome=draw | rounds=22 | replacements=0 | latency_p95=45.193ms
- Match 97 | seed=769480 | outcome=win(P1) | rounds=72 | replacements=0 | latency_p95=69.493ms
- Match 98 | seed=777399 | outcome=win(P2) | rounds=59 | replacements=0 | latency_p95=56.934ms
- Match 99 | seed=785318 | outcome=win(P1) | rounds=21 | replacements=0 | latency_p95=40.676ms
- Match 100 | seed=793237 | outcome=win(P2) | rounds=11 | replacements=0 | latency_p95=40.016ms