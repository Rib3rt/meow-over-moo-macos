# AI Strength Self-Play Report

- Generated: 2026-02-12 14:51:15
- Matches: 100
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `40` (40.00%)
- Player 2 wins: `38` (38.00%)
- Draws: `22` (22.00%)
- Avg rounds: `29.75`
- Decision latency median (ms): `15.849`
- Decision latency p95 (ms): `75.407`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 75
- `no_interaction_limit`: 22
- `opponent_no_units_or_supply`: 3

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=7142 | P1=3619 | P2=3523
- `attack`: total=3078 | P1=1550 | P2=1528
- `supply_deploy`: total=1332 | P1=671 | P2=661
- `repair`: total=155 | P1=65 | P2=90
- `skip`: total=30 | P1=17 | P2=13

## Unit Usecase Stats

- `Cloudstriker`: total=4688 | P1=2293 | P2=2395 | supply_deploy=363 | move=3138 | attack=1187
- `Artillery`: total=2096 | P1=1075 | P2=1021 | supply_deploy=255 | move=1105 | attack=736
- `Crusher`: total=1420 | P1=749 | P2=671 | supply_deploy=203 | move=848 | attack=369
- `Wingstalker`: total=1139 | P1=535 | P2=604 | supply_deploy=174 | move=722 | attack=243
- `Healer`: total=928 | P1=449 | P2=479 | supply_deploy=109 | move=509 | attack=155 | repair=155
- `Earthstalker`: total=860 | P1=477 | P2=383 | supply_deploy=155 | move=502 | attack=203
- `Bastion`: total=576 | P1=327 | P2=249 | supply_deploy=73 | move=318 | attack=185
- `SKIP_SLOT`: total=30 | P1=17 | P2=13 | skip=30

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=112.389ms
- Match 2 | seed=17175 | outcome=draw | rounds=32 | replacements=0 | latency_p95=59.870ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=37.438ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=30.608ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=42 | replacements=0 | latency_p95=70.183ms
- Match 6 | seed=48851 | outcome=draw | rounds=32 | replacements=0 | latency_p95=67.054ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=81 | replacements=0 | latency_p95=74.682ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=36.671ms
- Match 9 | seed=72608 | outcome=draw | rounds=88 | replacements=0 | latency_p95=112.582ms
- Match 10 | seed=80527 | outcome=win(P1) | rounds=63 | replacements=0 | latency_p95=68.141ms
- Match 11 | seed=88446 | outcome=draw | rounds=57 | replacements=0 | latency_p95=68.781ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=44 | replacements=0 | latency_p95=94.120ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=107.718ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=80.031ms
- Match 15 | seed=120122 | outcome=draw | rounds=46 | replacements=0 | latency_p95=88.313ms
- Match 16 | seed=128041 | outcome=draw | rounds=37 | replacements=0 | latency_p95=74.267ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=64.539ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=37 | replacements=0 | latency_p95=71.085ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=80.264ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=71 | replacements=0 | latency_p95=53.827ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=44.315ms
- Match 22 | seed=175555 | outcome=win(P1) | rounds=35 | replacements=0 | latency_p95=91.923ms
- Match 23 | seed=183474 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=28.918ms
- Match 24 | seed=191393 | outcome=draw | rounds=41 | replacements=0 | latency_p95=56.115ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=105.895ms
- Match 26 | seed=207231 | outcome=draw | rounds=41 | replacements=0 | latency_p95=70.825ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=39 | replacements=0 | latency_p95=50.337ms
- Match 28 | seed=223069 | outcome=win(P1) | rounds=49 | replacements=0 | latency_p95=97.258ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=64.304ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=59.103ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=40.420ms
- Match 32 | seed=254745 | outcome=win(P2) | rounds=19 | replacements=0 | latency_p95=117.895ms
- Match 33 | seed=262664 | outcome=draw | rounds=23 | replacements=0 | latency_p95=77.023ms
- Match 34 | seed=270583 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=47.821ms
- Match 35 | seed=278502 | outcome=draw | rounds=81 | replacements=0 | latency_p95=96.948ms
- Match 36 | seed=286421 | outcome=draw | rounds=61 | replacements=0 | latency_p95=78.292ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=79.235ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=94.642ms
- Match 39 | seed=310178 | outcome=win(P1) | rounds=24 | replacements=0 | latency_p95=86.582ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=54.036ms
- Match 41 | seed=326016 | outcome=win(P2) | rounds=59 | replacements=0 | latency_p95=54.064ms
- Match 42 | seed=333935 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=74.934ms
- Match 43 | seed=341854 | outcome=draw | rounds=33 | replacements=0 | latency_p95=67.883ms
- Match 44 | seed=349773 | outcome=draw | rounds=38 | replacements=0 | latency_p95=96.702ms
- Match 45 | seed=357692 | outcome=draw | rounds=55 | replacements=0 | latency_p95=95.912ms
- Match 46 | seed=365611 | outcome=win(P1) | rounds=83 | replacements=0 | latency_p95=80.695ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=92.641ms
- Match 48 | seed=381449 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=59.253ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=16 | replacements=0 | latency_p95=63.517ms
- Match 50 | seed=397287 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=25.814ms
- Match 51 | seed=405206 | outcome=win(P2) | rounds=75 | replacements=0 | latency_p95=75.125ms
- Match 52 | seed=413125 | outcome=win(P1) | rounds=63 | replacements=0 | latency_p95=57.109ms
- Match 53 | seed=421044 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=76.861ms
- Match 54 | seed=428963 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=52.926ms
- Match 55 | seed=436882 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=32.086ms
- Match 56 | seed=444801 | outcome=draw | rounds=41 | replacements=0 | latency_p95=92.063ms
- Match 57 | seed=452720 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=53.107ms
- Match 58 | seed=460639 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=51.940ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=51.800ms
- Match 60 | seed=476477 | outcome=win(P1) | rounds=45 | replacements=0 | latency_p95=68.602ms
- Match 61 | seed=484396 | outcome=win(P2) | rounds=24 | replacements=0 | latency_p95=63.713ms
- Match 62 | seed=492315 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=136.745ms
- Match 63 | seed=500234 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=58.937ms
- Match 64 | seed=508153 | outcome=draw | rounds=53 | replacements=0 | latency_p95=102.438ms
- Match 65 | seed=516072 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=37.042ms
- Match 66 | seed=523991 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=21.406ms
- Match 67 | seed=531910 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=59.470ms
- Match 68 | seed=539829 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=46.374ms
- Match 69 | seed=547748 | outcome=win(P2) | rounds=70 | replacements=0 | latency_p95=41.364ms
- Match 70 | seed=555667 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=60.947ms
- Match 71 | seed=563586 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=56.255ms
- Match 72 | seed=571505 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=70.348ms
- Match 73 | seed=579424 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=79.545ms
- Match 74 | seed=587343 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=86.660ms
- Match 75 | seed=595262 | outcome=draw | rounds=30 | replacements=0 | latency_p95=63.004ms
- Match 76 | seed=603181 | outcome=win(P1) | rounds=48 | replacements=0 | latency_p95=46.422ms
- Match 77 | seed=611100 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=59.931ms
- Match 78 | seed=619019 | outcome=draw | rounds=57 | replacements=0 | latency_p95=57.352ms
- Match 79 | seed=626938 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=53.523ms
- Match 80 | seed=634857 | outcome=win(P1) | rounds=58 | replacements=0 | latency_p95=51.014ms
- Match 81 | seed=642776 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=58.881ms
- Match 82 | seed=650695 | outcome=draw | rounds=32 | replacements=0 | latency_p95=74.587ms
- Match 83 | seed=658614 | outcome=win(P1) | rounds=5 | replacements=0 | latency_p95=42.259ms
- Match 84 | seed=666533 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=71.701ms
- Match 85 | seed=674452 | outcome=win(P2) | rounds=27 | replacements=0 | latency_p95=88.555ms
- Match 86 | seed=682371 | outcome=win(P2) | rounds=30 | replacements=0 | latency_p95=57.541ms
- Match 87 | seed=690290 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=43.164ms
- Match 88 | seed=698209 | outcome=draw | rounds=71 | replacements=0 | latency_p95=52.134ms
- Match 89 | seed=706128 | outcome=win(P1) | rounds=10 | replacements=0 | latency_p95=67.022ms
- Match 90 | seed=714047 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=51.300ms
- Match 91 | seed=721966 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=81.792ms
- Match 92 | seed=729885 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=84.938ms
- Match 93 | seed=737804 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=80.960ms
- Match 94 | seed=745723 | outcome=win(P1) | rounds=26 | replacements=0 | latency_p95=80.968ms
- Match 95 | seed=753642 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=58.166ms
- Match 96 | seed=761561 | outcome=draw | rounds=22 | replacements=0 | latency_p95=45.126ms
- Match 97 | seed=769480 | outcome=draw | rounds=61 | replacements=0 | latency_p95=66.429ms
- Match 98 | seed=777399 | outcome=win(P2) | rounds=33 | replacements=0 | latency_p95=52.516ms
- Match 99 | seed=785318 | outcome=win(P1) | rounds=21 | replacements=0 | latency_p95=41.226ms
- Match 100 | seed=793237 | outcome=win(P2) | rounds=54 | replacements=0 | latency_p95=40.138ms