# AI Strength Self-Play Report

- Generated: 2026-02-12 16:39:28
- Matches: 100
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `45` (45.00%)
- Player 2 wins: `40` (40.00%)
- Draws: `15` (15.00%)
- Avg rounds: `30.97`
- Decision latency median (ms): `17.615`
- Decision latency p95 (ms): `81.529`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 83
- `no_interaction_limit`: 15
- `opponent_no_units_or_supply`: 2

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=7490 | P1=3794 | P2=3696
- `attack`: total=3198 | P1=1598 | P2=1600
- `supply_deploy`: total=1337 | P1=675 | P2=662
- `repair`: total=162 | P1=86 | P2=76
- `skip`: total=41 | P1=10 | P2=31

## Unit Usecase Stats

- `Cloudstriker`: total=4695 | P1=2343 | P2=2352 | supply_deploy=364 | move=3104 | attack=1227
- `Artillery`: total=1959 | P1=1009 | P2=950 | supply_deploy=255 | move=1023 | attack=681
- `Crusher`: total=1465 | P1=760 | P2=705 | supply_deploy=189 | move=908 | attack=368
- `Wingstalker`: total=1142 | P1=580 | P2=562 | supply_deploy=173 | move=734 | attack=235
- `Earthstalker`: total=1060 | P1=542 | P2=518 | supply_deploy=156 | move=637 | attack=267
- `Healer`: total=955 | P1=500 | P2=455 | supply_deploy=113 | move=505 | attack=175 | repair=162
- `Bastion`: total=911 | P1=419 | P2=492 | supply_deploy=87 | move=579 | attack=245
- `SKIP_SLOT`: total=41 | P1=10 | P2=31 | skip=41

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=108.963ms
- Match 2 | seed=17175 | outcome=win(P2) | rounds=40 | replacements=0 | latency_p95=72.035ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=38.435ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=30.142ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=38 | replacements=0 | latency_p95=91.808ms
- Match 6 | seed=48851 | outcome=win(P1) | rounds=94 | replacements=0 | latency_p95=75.177ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=64.681ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=35.998ms
- Match 9 | seed=72608 | outcome=win(P2) | rounds=78 | replacements=0 | latency_p95=133.726ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=62 | replacements=0 | latency_p95=71.758ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=77 | replacements=0 | latency_p95=70.251ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=55.318ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=107.824ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=79.755ms
- Match 15 | seed=120122 | outcome=win(P2) | rounds=109 | replacements=0 | latency_p95=103.616ms
- Match 16 | seed=128041 | outcome=win(P1) | rounds=77 | replacements=0 | latency_p95=86.028ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=83.938ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=41 | replacements=0 | latency_p95=68.357ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=80.044ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=38.092ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=44.441ms
- Match 22 | seed=175555 | outcome=draw | rounds=76 | replacements=0 | latency_p95=87.441ms
- Match 23 | seed=183474 | outcome=win(P1) | rounds=28 | replacements=0 | latency_p95=40.354ms
- Match 24 | seed=191393 | outcome=win(P1) | rounds=40 | replacements=0 | latency_p95=68.344ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=104.537ms
- Match 26 | seed=207231 | outcome=draw | rounds=53 | replacements=0 | latency_p95=71.734ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=38 | replacements=0 | latency_p95=61.239ms
- Match 28 | seed=223069 | outcome=win(P2) | rounds=70 | replacements=0 | latency_p95=91.481ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=64.149ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=58.206ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=39.764ms
- Match 32 | seed=254745 | outcome=win(P2) | rounds=36 | replacements=0 | latency_p95=99.209ms
- Match 33 | seed=262664 | outcome=draw | rounds=37 | replacements=0 | latency_p95=58.093ms
- Match 34 | seed=270583 | outcome=win(P1) | rounds=19 | replacements=0 | latency_p95=49.320ms
- Match 35 | seed=278502 | outcome=draw | rounds=47 | replacements=0 | latency_p95=121.141ms
- Match 36 | seed=286421 | outcome=draw | rounds=51 | replacements=0 | latency_p95=77.213ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=23 | replacements=0 | latency_p95=75.801ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=94.550ms
- Match 39 | seed=310178 | outcome=draw | rounds=41 | replacements=0 | latency_p95=87.484ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=53.838ms
- Match 41 | seed=326016 | outcome=win(P2) | rounds=25 | replacements=0 | latency_p95=53.996ms
- Match 42 | seed=333935 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=76.013ms
- Match 43 | seed=341854 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=71.508ms
- Match 44 | seed=349773 | outcome=win(P2) | rounds=83 | replacements=0 | latency_p95=79.513ms
- Match 45 | seed=357692 | outcome=draw | rounds=25 | replacements=0 | latency_p95=237.335ms
- Match 46 | seed=365611 | outcome=draw | rounds=38 | replacements=0 | latency_p95=76.612ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=94.226ms
- Match 48 | seed=381449 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=60.591ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=75.879ms
- Match 50 | seed=397287 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=26.407ms
- Match 51 | seed=405206 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=100.598ms
- Match 52 | seed=413125 | outcome=draw | rounds=51 | replacements=0 | latency_p95=40.492ms
- Match 53 | seed=421044 | outcome=win(P2) | rounds=22 | replacements=0 | latency_p95=45.950ms
- Match 54 | seed=428963 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=53.731ms
- Match 55 | seed=436882 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=33.253ms
- Match 56 | seed=444801 | outcome=win(P1) | rounds=88 | replacements=0 | latency_p95=103.448ms
- Match 57 | seed=452720 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=54.335ms
- Match 58 | seed=460639 | outcome=draw | rounds=29 | replacements=0 | latency_p95=89.456ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=52.721ms
- Match 60 | seed=476477 | outcome=draw | rounds=55 | replacements=0 | latency_p95=74.160ms
- Match 61 | seed=484396 | outcome=win(P1) | rounds=40 | replacements=0 | latency_p95=65.489ms
- Match 62 | seed=492315 | outcome=win(P1) | rounds=46 | replacements=0 | latency_p95=61.011ms
- Match 63 | seed=500234 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=60.653ms
- Match 64 | seed=508153 | outcome=win(P2) | rounds=92 | replacements=0 | latency_p95=104.376ms
- Match 65 | seed=516072 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=38.414ms
- Match 66 | seed=523991 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=22.551ms
- Match 67 | seed=531910 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=61.575ms
- Match 68 | seed=539829 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=47.513ms
- Match 69 | seed=547748 | outcome=win(P1) | rounds=59 | replacements=0 | latency_p95=101.389ms
- Match 70 | seed=555667 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=62.678ms
- Match 71 | seed=563586 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=61.748ms
- Match 72 | seed=571505 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=72.660ms
- Match 73 | seed=579424 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=80.443ms
- Match 74 | seed=587343 | outcome=draw | rounds=24 | replacements=0 | latency_p95=83.129ms
- Match 75 | seed=595262 | outcome=draw | rounds=28 | replacements=0 | latency_p95=64.460ms
- Match 76 | seed=603181 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=66.861ms
- Match 77 | seed=611100 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=62.325ms
- Match 78 | seed=619019 | outcome=win(P1) | rounds=39 | replacements=0 | latency_p95=67.859ms
- Match 79 | seed=626938 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=54.566ms
- Match 80 | seed=634857 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=51.112ms
- Match 81 | seed=642776 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=60.407ms
- Match 82 | seed=650695 | outcome=win(P2) | rounds=85 | replacements=0 | latency_p95=86.149ms
- Match 83 | seed=658614 | outcome=win(P1) | rounds=5 | replacements=0 | latency_p95=43.354ms
- Match 84 | seed=666533 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=73.166ms
- Match 85 | seed=674452 | outcome=win(P1) | rounds=97 | replacements=0 | latency_p95=80.606ms
- Match 86 | seed=682371 | outcome=win(P2) | rounds=30 | replacements=0 | latency_p95=59.073ms
- Match 87 | seed=690290 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=44.263ms
- Match 88 | seed=698209 | outcome=win(P2) | rounds=34 | replacements=0 | latency_p95=62.204ms
- Match 89 | seed=706128 | outcome=win(P1) | rounds=10 | replacements=0 | latency_p95=69.245ms
- Match 90 | seed=714047 | outcome=draw | rounds=47 | replacements=0 | latency_p95=52.976ms
- Match 91 | seed=721966 | outcome=win(P2) | rounds=80 | replacements=0 | latency_p95=96.612ms
- Match 92 | seed=729885 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=87.086ms
- Match 93 | seed=737804 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=82.647ms
- Match 94 | seed=745723 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=101.080ms
- Match 95 | seed=753642 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=59.446ms
- Match 96 | seed=761561 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=36.742ms
- Match 97 | seed=769480 | outcome=win(P1) | rounds=21 | replacements=0 | latency_p95=81.353ms
- Match 98 | seed=777399 | outcome=win(P2) | rounds=14 | replacements=0 | latency_p95=46.973ms
- Match 99 | seed=785318 | outcome=draw | rounds=32 | replacements=0 | latency_p95=49.896ms
- Match 100 | seed=793237 | outcome=win(P2) | rounds=11 | replacements=0 | latency_p95=40.586ms