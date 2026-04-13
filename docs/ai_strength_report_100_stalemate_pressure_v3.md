# AI Strength Self-Play Report

- Generated: 2026-02-12 15:18:03
- Matches: 100
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `45` (45.00%)
- Player 2 wins: `37` (37.00%)
- Draws: `18` (18.00%)
- Avg rounds: `30.20`
- Decision latency median (ms): `15.278`
- Decision latency p95 (ms): `70.626`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 81
- `no_interaction_limit`: 18
- `opponent_no_units_or_supply`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=7214 | P1=3649 | P2=3565
- `attack`: total=3144 | P1=1601 | P2=1543
- `supply_deploy`: total=1347 | P1=685 | P2=662
- `repair`: total=157 | P1=58 | P2=99
- `skip`: total=51 | P1=15 | P2=36

## Unit Usecase Stats

- `Cloudstriker`: total=4643 | P1=2313 | P2=2330 | supply_deploy=363 | move=3096 | attack=1184
- `Artillery`: total=2065 | P1=1089 | P2=976 | supply_deploy=255 | move=1089 | attack=721
- `Crusher`: total=1406 | P1=680 | P2=726 | supply_deploy=202 | move=814 | attack=390
- `Wingstalker`: total=1159 | P1=515 | P2=644 | supply_deploy=177 | move=759 | attack=223
- `Earthstalker`: total=1005 | P1=521 | P2=484 | supply_deploy=156 | move=604 | attack=245
- `Healer`: total=895 | P1=446 | P2=449 | supply_deploy=112 | move=461 | attack=165 | repair=157
- `Bastion`: total=689 | P1=429 | P2=260 | supply_deploy=82 | move=391 | attack=216
- `SKIP_SLOT`: total=51 | P1=15 | P2=36 | skip=51

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=104.666ms
- Match 2 | seed=17175 | outcome=draw | rounds=32 | replacements=0 | latency_p95=56.601ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=35.802ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=28.436ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=35 | replacements=0 | latency_p95=68.390ms
- Match 6 | seed=48851 | outcome=draw | rounds=34 | replacements=0 | latency_p95=66.011ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=75 | replacements=0 | latency_p95=74.956ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=34.255ms
- Match 9 | seed=72608 | outcome=win(P2) | rounds=88 | replacements=0 | latency_p95=84.108ms
- Match 10 | seed=80527 | outcome=draw | rounds=42 | replacements=0 | latency_p95=64.095ms
- Match 11 | seed=88446 | outcome=draw | rounds=40 | replacements=0 | latency_p95=63.044ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=52.070ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=102.402ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=76.566ms
- Match 15 | seed=120122 | outcome=draw | rounds=24 | replacements=0 | latency_p95=97.428ms
- Match 16 | seed=128041 | outcome=draw | rounds=56 | replacements=0 | latency_p95=65.436ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=65.593ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=37 | replacements=0 | latency_p95=69.957ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=75.711ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=41 | replacements=0 | latency_p95=51.388ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=41.705ms
- Match 22 | seed=175555 | outcome=win(P1) | rounds=40 | replacements=0 | latency_p95=83.002ms
- Match 23 | seed=183474 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=28.185ms
- Match 24 | seed=191393 | outcome=draw | rounds=41 | replacements=0 | latency_p95=53.331ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=100.101ms
- Match 26 | seed=207231 | outcome=draw | rounds=65 | replacements=0 | latency_p95=59.268ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=39 | replacements=0 | latency_p95=48.268ms
- Match 28 | seed=223069 | outcome=draw | rounds=47 | replacements=0 | latency_p95=82.938ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=60.331ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=56.112ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=38.147ms
- Match 32 | seed=254745 | outcome=win(P1) | rounds=22 | replacements=0 | latency_p95=94.306ms
- Match 33 | seed=262664 | outcome=draw | rounds=23 | replacements=0 | latency_p95=73.103ms
- Match 34 | seed=270583 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=45.782ms
- Match 35 | seed=278502 | outcome=win(P2) | rounds=75 | replacements=0 | latency_p95=92.332ms
- Match 36 | seed=286421 | outcome=win(P2) | rounds=79 | replacements=0 | latency_p95=89.855ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=23 | replacements=0 | latency_p95=71.360ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=90.261ms
- Match 39 | seed=310178 | outcome=win(P1) | rounds=24 | replacements=0 | latency_p95=82.580ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=50.882ms
- Match 41 | seed=326016 | outcome=win(P1) | rounds=82 | replacements=0 | latency_p95=51.561ms
- Match 42 | seed=333935 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=73.189ms
- Match 43 | seed=341854 | outcome=draw | rounds=37 | replacements=0 | latency_p95=65.322ms
- Match 44 | seed=349773 | outcome=draw | rounds=37 | replacements=0 | latency_p95=91.715ms
- Match 45 | seed=357692 | outcome=win(P2) | rounds=54 | replacements=0 | latency_p95=74.219ms
- Match 46 | seed=365611 | outcome=win(P1) | rounds=85 | replacements=0 | latency_p95=68.414ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=89.257ms
- Match 48 | seed=381449 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=59.930ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=16 | replacements=0 | latency_p95=62.460ms
- Match 50 | seed=397287 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=25.154ms
- Match 51 | seed=405206 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=95.781ms
- Match 52 | seed=413125 | outcome=win(P1) | rounds=61 | replacements=0 | latency_p95=39.589ms
- Match 53 | seed=421044 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=75.505ms
- Match 54 | seed=428963 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=52.413ms
- Match 55 | seed=436882 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=32.133ms
- Match 56 | seed=444801 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=83.755ms
- Match 57 | seed=452720 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=52.035ms
- Match 58 | seed=460639 | outcome=draw | rounds=29 | replacements=0 | latency_p95=81.711ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=50.758ms
- Match 60 | seed=476477 | outcome=win(P1) | rounds=45 | replacements=0 | latency_p95=66.485ms
- Match 61 | seed=484396 | outcome=draw | rounds=51 | replacements=0 | latency_p95=63.329ms
- Match 62 | seed=492315 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=133.292ms
- Match 63 | seed=500234 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=57.768ms
- Match 64 | seed=508153 | outcome=win(P1) | rounds=99 | replacements=0 | latency_p95=85.229ms
- Match 65 | seed=516072 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=36.627ms
- Match 66 | seed=523991 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=21.266ms
- Match 67 | seed=531910 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=58.941ms
- Match 68 | seed=539829 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=45.938ms
- Match 69 | seed=547748 | outcome=win(P1) | rounds=63 | replacements=0 | latency_p95=46.061ms
- Match 70 | seed=555667 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=60.390ms
- Match 71 | seed=563586 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=55.224ms
- Match 72 | seed=571505 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=68.552ms
- Match 73 | seed=579424 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=78.996ms
- Match 74 | seed=587343 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=85.901ms
- Match 75 | seed=595262 | outcome=draw | rounds=30 | replacements=0 | latency_p95=61.316ms
- Match 76 | seed=603181 | outcome=win(P1) | rounds=45 | replacements=0 | latency_p95=46.863ms
- Match 77 | seed=611100 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=59.410ms
- Match 78 | seed=619019 | outcome=draw | rounds=57 | replacements=0 | latency_p95=57.038ms
- Match 79 | seed=626938 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=52.370ms
- Match 80 | seed=634857 | outcome=win(P1) | rounds=48 | replacements=0 | latency_p95=52.893ms
- Match 81 | seed=642776 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=58.377ms
- Match 82 | seed=650695 | outcome=win(P1) | rounds=78 | replacements=0 | latency_p95=74.255ms
- Match 83 | seed=658614 | outcome=win(P1) | rounds=5 | replacements=0 | latency_p95=41.520ms
- Match 84 | seed=666533 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=70.350ms
- Match 85 | seed=674452 | outcome=win(P2) | rounds=27 | replacements=0 | latency_p95=86.986ms
- Match 86 | seed=682371 | outcome=win(P2) | rounds=30 | replacements=0 | latency_p95=55.932ms
- Match 87 | seed=690290 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=42.756ms
- Match 88 | seed=698209 | outcome=draw | rounds=58 | replacements=0 | latency_p95=62.803ms
- Match 89 | seed=706128 | outcome=win(P1) | rounds=10 | replacements=0 | latency_p95=65.685ms
- Match 90 | seed=714047 | outcome=draw | rounds=47 | replacements=0 | latency_p95=46.628ms
- Match 91 | seed=721966 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=80.100ms
- Match 92 | seed=729885 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=83.519ms
- Match 93 | seed=737804 | outcome=win(P2) | rounds=60 | replacements=0 | latency_p95=82.034ms
- Match 94 | seed=745723 | outcome=win(P1) | rounds=26 | replacements=0 | latency_p95=80.998ms
- Match 95 | seed=753642 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=57.451ms
- Match 96 | seed=761561 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=45.413ms
- Match 97 | seed=769480 | outcome=win(P1) | rounds=72 | replacements=0 | latency_p95=67.830ms
- Match 98 | seed=777399 | outcome=win(P2) | rounds=59 | replacements=0 | latency_p95=55.448ms
- Match 99 | seed=785318 | outcome=win(P1) | rounds=21 | replacements=0 | latency_p95=40.677ms
- Match 100 | seed=793237 | outcome=win(P2) | rounds=11 | replacements=0 | latency_p95=38.644ms