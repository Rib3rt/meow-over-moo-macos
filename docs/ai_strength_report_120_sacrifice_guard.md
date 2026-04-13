# AI Strength Self-Play Report

- Generated: 2026-02-12 16:07:51
- Matches: 120
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `54` (45.00%)
- Player 2 wins: `46` (38.33%)
- Draws: `20` (16.67%)
- Avg rounds: `31.52`
- Decision latency median (ms): `16.981`
- Decision latency p95 (ms): `79.080`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 98
- `no_interaction_limit`: 20
- `opponent_no_units_or_supply`: 2

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=9180 | P1=4643 | P2=4537
- `attack`: total=3876 | P1=1941 | P2=1935
- `supply_deploy`: total=1629 | P1=825 | P2=804
- `repair`: total=200 | P1=102 | P2=98
- `skip`: total=49 | P1=18 | P2=31

## Unit Usecase Stats

- `Cloudstriker`: total=5644 | P1=2847 | P2=2797 | supply_deploy=439 | move=3741 | attack=1464
- `Artillery`: total=2412 | P1=1255 | P2=1157 | supply_deploy=309 | move=1276 | attack=827
- `Crusher`: total=1824 | P1=927 | P2=897 | supply_deploy=232 | move=1124 | attack=468
- `Wingstalker`: total=1437 | P1=720 | P2=717 | supply_deploy=212 | move=927 | attack=298
- `Earthstalker`: total=1316 | P1=657 | P2=659 | supply_deploy=194 | move=812 | attack=310
- `Healer`: total=1133 | P1=587 | P2=546 | supply_deploy=135 | move=600 | attack=198 | repair=200
- `Bastion`: total=1119 | P1=518 | P2=601 | supply_deploy=108 | move=700 | attack=311
- `SKIP_SLOT`: total=49 | P1=18 | P2=31 | skip=49

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=99.616ms
- Match 2 | seed=17175 | outcome=win(P2) | rounds=40 | replacements=0 | latency_p95=67.656ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=35.915ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=28.812ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=38 | replacements=0 | latency_p95=85.754ms
- Match 6 | seed=48851 | outcome=win(P1) | rounds=94 | replacements=0 | latency_p95=71.008ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=60.360ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=34.757ms
- Match 9 | seed=72608 | outcome=win(P2) | rounds=78 | replacements=0 | latency_p95=126.346ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=62 | replacements=0 | latency_p95=68.668ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=77 | replacements=0 | latency_p95=67.033ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=51.576ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=102.579ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=77.010ms
- Match 15 | seed=120122 | outcome=win(P2) | rounds=109 | replacements=0 | latency_p95=98.526ms
- Match 16 | seed=128041 | outcome=win(P1) | rounds=77 | replacements=0 | latency_p95=82.713ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=79.909ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=41 | replacements=0 | latency_p95=66.093ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=76.574ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=36.556ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=41.832ms
- Match 22 | seed=175555 | outcome=draw | rounds=76 | replacements=0 | latency_p95=83.114ms
- Match 23 | seed=183474 | outcome=win(P1) | rounds=28 | replacements=0 | latency_p95=38.493ms
- Match 24 | seed=191393 | outcome=win(P1) | rounds=40 | replacements=0 | latency_p95=65.311ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=100.238ms
- Match 26 | seed=207231 | outcome=draw | rounds=53 | replacements=0 | latency_p95=68.129ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=38 | replacements=0 | latency_p95=58.586ms
- Match 28 | seed=223069 | outcome=win(P2) | rounds=70 | replacements=0 | latency_p95=87.210ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=61.968ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=57.189ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=39.578ms
- Match 32 | seed=254745 | outcome=win(P2) | rounds=36 | replacements=0 | latency_p95=94.830ms
- Match 33 | seed=262664 | outcome=draw | rounds=37 | replacements=0 | latency_p95=55.449ms
- Match 34 | seed=270583 | outcome=win(P1) | rounds=19 | replacements=0 | latency_p95=47.253ms
- Match 35 | seed=278502 | outcome=draw | rounds=47 | replacements=0 | latency_p95=117.228ms
- Match 36 | seed=286421 | outcome=draw | rounds=51 | replacements=0 | latency_p95=74.226ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=23 | replacements=0 | latency_p95=72.870ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=90.762ms
- Match 39 | seed=310178 | outcome=draw | rounds=41 | replacements=0 | latency_p95=84.586ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=52.594ms
- Match 41 | seed=326016 | outcome=win(P2) | rounds=25 | replacements=0 | latency_p95=52.053ms
- Match 42 | seed=333935 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=72.842ms
- Match 43 | seed=341854 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=69.213ms
- Match 44 | seed=349773 | outcome=win(P2) | rounds=83 | replacements=0 | latency_p95=76.922ms
- Match 45 | seed=357692 | outcome=draw | rounds=25 | replacements=0 | latency_p95=230.190ms
- Match 46 | seed=365611 | outcome=draw | rounds=38 | replacements=0 | latency_p95=74.787ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=90.927ms
- Match 48 | seed=381449 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=58.801ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=73.990ms
- Match 50 | seed=397287 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=26.048ms
- Match 51 | seed=405206 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=97.040ms
- Match 52 | seed=413125 | outcome=draw | rounds=51 | replacements=0 | latency_p95=39.582ms
- Match 53 | seed=421044 | outcome=win(P2) | rounds=22 | replacements=0 | latency_p95=44.721ms
- Match 54 | seed=428963 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=52.983ms
- Match 55 | seed=436882 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=32.293ms
- Match 56 | seed=444801 | outcome=win(P1) | rounds=88 | replacements=0 | latency_p95=99.025ms
- Match 57 | seed=452720 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=52.762ms
- Match 58 | seed=460639 | outcome=draw | rounds=29 | replacements=0 | latency_p95=87.218ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=51.564ms
- Match 60 | seed=476477 | outcome=draw | rounds=55 | replacements=0 | latency_p95=72.626ms
- Match 61 | seed=484396 | outcome=win(P1) | rounds=40 | replacements=0 | latency_p95=63.688ms
- Match 62 | seed=492315 | outcome=win(P1) | rounds=46 | replacements=0 | latency_p95=59.371ms
- Match 63 | seed=500234 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=58.615ms
- Match 64 | seed=508153 | outcome=win(P2) | rounds=92 | replacements=0 | latency_p95=101.937ms
- Match 65 | seed=516072 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=36.465ms
- Match 66 | seed=523991 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=21.424ms
- Match 67 | seed=531910 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=58.516ms
- Match 68 | seed=539829 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=45.610ms
- Match 69 | seed=547748 | outcome=win(P1) | rounds=59 | replacements=0 | latency_p95=96.762ms
- Match 70 | seed=555667 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=59.790ms
- Match 71 | seed=563586 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=59.443ms
- Match 72 | seed=571505 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=69.489ms
- Match 73 | seed=579424 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=78.435ms
- Match 74 | seed=587343 | outcome=draw | rounds=24 | replacements=0 | latency_p95=80.006ms
- Match 75 | seed=595262 | outcome=draw | rounds=28 | replacements=0 | latency_p95=62.384ms
- Match 76 | seed=603181 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=64.597ms
- Match 77 | seed=611100 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=59.999ms
- Match 78 | seed=619019 | outcome=win(P1) | rounds=39 | replacements=0 | latency_p95=65.487ms
- Match 79 | seed=626938 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=53.120ms
- Match 80 | seed=634857 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=50.550ms
- Match 81 | seed=642776 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=59.271ms
- Match 82 | seed=650695 | outcome=win(P2) | rounds=85 | replacements=0 | latency_p95=83.824ms
- Match 83 | seed=658614 | outcome=win(P1) | rounds=5 | replacements=0 | latency_p95=42.408ms
- Match 84 | seed=666533 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=74.521ms
- Match 85 | seed=674452 | outcome=win(P1) | rounds=97 | replacements=0 | latency_p95=79.530ms
- Match 86 | seed=682371 | outcome=win(P2) | rounds=30 | replacements=0 | latency_p95=57.704ms
- Match 87 | seed=690290 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=44.277ms
- Match 88 | seed=698209 | outcome=win(P2) | rounds=34 | replacements=0 | latency_p95=62.881ms
- Match 89 | seed=706128 | outcome=win(P1) | rounds=10 | replacements=0 | latency_p95=68.430ms
- Match 90 | seed=714047 | outcome=draw | rounds=47 | replacements=0 | latency_p95=52.112ms
- Match 91 | seed=721966 | outcome=win(P2) | rounds=80 | replacements=0 | latency_p95=95.697ms
- Match 92 | seed=729885 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=86.147ms
- Match 93 | seed=737804 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=81.800ms
- Match 94 | seed=745723 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=100.563ms
- Match 95 | seed=753642 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=58.847ms
- Match 96 | seed=761561 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=37.170ms
- Match 97 | seed=769480 | outcome=win(P1) | rounds=21 | replacements=0 | latency_p95=81.083ms
- Match 98 | seed=777399 | outcome=win(P2) | rounds=14 | replacements=0 | latency_p95=46.493ms
- Match 99 | seed=785318 | outcome=draw | rounds=32 | replacements=0 | latency_p95=49.692ms
- Match 100 | seed=793237 | outcome=win(P2) | rounds=11 | replacements=0 | latency_p95=39.973ms
- Match 101 | seed=801156 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=66.520ms
- Match 102 | seed=809075 | outcome=draw | rounds=95 | replacements=0 | latency_p95=85.221ms
- Match 103 | seed=816994 | outcome=draw | rounds=29 | replacements=0 | latency_p95=102.129ms
- Match 104 | seed=824913 | outcome=win(P2) | rounds=68 | replacements=0 | latency_p95=59.360ms
- Match 105 | seed=832832 | outcome=win(P1) | rounds=87 | replacements=0 | latency_p95=100.794ms
- Match 106 | seed=840751 | outcome=draw | rounds=69 | replacements=0 | latency_p95=75.898ms
- Match 107 | seed=848670 | outcome=win(P1) | rounds=31 | replacements=0 | latency_p95=62.021ms
- Match 108 | seed=856589 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=67.933ms
- Match 109 | seed=864508 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=45.438ms
- Match 110 | seed=872427 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=113.558ms
- Match 111 | seed=880346 | outcome=win(P2) | rounds=20 | replacements=0 | latency_p95=58.364ms
- Match 112 | seed=888265 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=98.310ms
- Match 113 | seed=896184 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=80.141ms
- Match 114 | seed=904103 | outcome=win(P1) | rounds=41 | replacements=0 | latency_p95=73.295ms
- Match 115 | seed=912022 | outcome=draw | rounds=45 | replacements=0 | latency_p95=62.874ms
- Match 116 | seed=919941 | outcome=win(P1) | rounds=68 | replacements=0 | latency_p95=69.694ms
- Match 117 | seed=927860 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=87.867ms
- Match 118 | seed=935779 | outcome=draw | rounds=23 | replacements=0 | latency_p95=42.957ms
- Match 119 | seed=943698 | outcome=win(P1) | rounds=19 | replacements=0 | latency_p95=80.448ms
- Match 120 | seed=951617 | outcome=win(P2) | rounds=16 | replacements=0 | latency_p95=30.000ms