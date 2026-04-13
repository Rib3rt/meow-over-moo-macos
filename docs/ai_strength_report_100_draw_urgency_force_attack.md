# AI Strength Self-Play Report

- Generated: 2026-02-12 14:42:53
- Matches: 100
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `39` (39.00%)
- Player 2 wins: `38` (38.00%)
- Draws: `23` (23.00%)
- Avg rounds: `27.88`
- Decision latency median (ms): `16.731`
- Decision latency p95 (ms): `80.238`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 75
- `no_interaction_limit`: 23
- `opponent_no_units_or_supply`: 2

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=6653 | P1=3383 | P2=3270
- `attack`: total=2895 | P1=1438 | P2=1457
- `supply_deploy`: total=1270 | P1=647 | P2=623
- `repair`: total=154 | P1=64 | P2=90
- `skip`: total=21 | P1=18 | P2=3

## Unit Usecase Stats

- `Cloudstriker`: total=4627 | P1=2267 | P2=2360 | supply_deploy=363 | move=3091 | attack=1173
- `Artillery`: total=2010 | P1=1052 | P2=958 | supply_deploy=253 | move=1039 | attack=718
- `Crusher`: total=1127 | P1=573 | P2=554 | supply_deploy=179 | move=653 | attack=295
- `Wingstalker`: total=1060 | P1=494 | P2=566 | supply_deploy=168 | move=698 | attack=194
- `Healer`: total=873 | P1=441 | P2=432 | supply_deploy=108 | move=464 | attack=147 | repair=154
- `Earthstalker`: total=768 | P1=410 | P2=358 | supply_deploy=141 | move=418 | attack=209
- `Bastion`: total=507 | P1=295 | P2=212 | supply_deploy=58 | move=290 | attack=159
- `SKIP_SLOT`: total=21 | P1=18 | P2=3 | skip=21

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=114.411ms
- Match 2 | seed=17175 | outcome=draw | rounds=32 | replacements=0 | latency_p95=62.182ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=39.329ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=31.471ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=41 | replacements=0 | latency_p95=72.425ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=72 | replacements=0 | latency_p95=119.929ms
- Match 7 | seed=56770 | outcome=draw | rounds=43 | replacements=0 | latency_p95=66.720ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=37.620ms
- Match 9 | seed=72608 | outcome=draw | rounds=58 | replacements=0 | latency_p95=101.983ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=76 | replacements=0 | latency_p95=74.884ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=38 | replacements=0 | latency_p95=64.400ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=44 | replacements=0 | latency_p95=97.030ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=112.253ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=83.518ms
- Match 15 | seed=120122 | outcome=draw | rounds=37 | replacements=0 | latency_p95=89.132ms
- Match 16 | seed=128041 | outcome=draw | rounds=37 | replacements=0 | latency_p95=71.033ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=66.616ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=37 | replacements=0 | latency_p95=73.516ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=83.766ms
- Match 20 | seed=159717 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=76.188ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=45.552ms
- Match 22 | seed=175555 | outcome=win(P1) | rounds=35 | replacements=0 | latency_p95=95.002ms
- Match 23 | seed=183474 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=30.063ms
- Match 24 | seed=191393 | outcome=draw | rounds=41 | replacements=0 | latency_p95=54.711ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=108.259ms
- Match 26 | seed=207231 | outcome=draw | rounds=41 | replacements=0 | latency_p95=73.732ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=39 | replacements=0 | latency_p95=51.548ms
- Match 28 | seed=223069 | outcome=win(P1) | rounds=81 | replacements=0 | latency_p95=109.902ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=66.711ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=60.664ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=41.040ms
- Match 32 | seed=254745 | outcome=draw | rounds=14 | replacements=0 | latency_p95=112.505ms
- Match 33 | seed=262664 | outcome=draw | rounds=23 | replacements=0 | latency_p95=79.907ms
- Match 34 | seed=270583 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=49.172ms
- Match 35 | seed=278502 | outcome=draw | rounds=36 | replacements=0 | latency_p95=108.858ms
- Match 36 | seed=286421 | outcome=draw | rounds=49 | replacements=0 | latency_p95=97.995ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=81.052ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=98.710ms
- Match 39 | seed=310178 | outcome=win(P1) | rounds=24 | replacements=0 | latency_p95=89.907ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=56.506ms
- Match 41 | seed=326016 | outcome=win(P2) | rounds=59 | replacements=0 | latency_p95=55.333ms
- Match 42 | seed=333935 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=78.138ms
- Match 43 | seed=341854 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=69.454ms
- Match 44 | seed=349773 | outcome=draw | rounds=29 | replacements=0 | latency_p95=101.214ms
- Match 45 | seed=357692 | outcome=draw | rounds=38 | replacements=0 | latency_p95=101.682ms
- Match 46 | seed=365611 | outcome=win(P2) | rounds=76 | replacements=0 | latency_p95=92.387ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=97.910ms
- Match 48 | seed=381449 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=62.891ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=16 | replacements=0 | latency_p95=67.145ms
- Match 50 | seed=397287 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=27.830ms
- Match 51 | seed=405206 | outcome=win(P1) | rounds=65 | replacements=0 | latency_p95=80.448ms
- Match 52 | seed=413125 | outcome=draw | rounds=23 | replacements=0 | latency_p95=45.434ms
- Match 53 | seed=421044 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=81.503ms
- Match 54 | seed=428963 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=56.724ms
- Match 55 | seed=436882 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=34.127ms
- Match 56 | seed=444801 | outcome=draw | rounds=41 | replacements=0 | latency_p95=99.316ms
- Match 57 | seed=452720 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=56.514ms
- Match 58 | seed=460639 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=53.958ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=55.727ms
- Match 60 | seed=476477 | outcome=win(P1) | rounds=45 | replacements=0 | latency_p95=74.003ms
- Match 61 | seed=484396 | outcome=win(P2) | rounds=24 | replacements=0 | latency_p95=67.982ms
- Match 62 | seed=492315 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=146.291ms
- Match 63 | seed=500234 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=62.790ms
- Match 64 | seed=508153 | outcome=draw | rounds=84 | replacements=0 | latency_p95=98.135ms
- Match 65 | seed=516072 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=39.945ms
- Match 66 | seed=523991 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=23.149ms
- Match 67 | seed=531910 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=62.973ms
- Match 68 | seed=539829 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=49.303ms
- Match 69 | seed=547748 | outcome=win(P2) | rounds=70 | replacements=0 | latency_p95=43.745ms
- Match 70 | seed=555667 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=64.765ms
- Match 71 | seed=563586 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=59.682ms
- Match 72 | seed=571505 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=75.158ms
- Match 73 | seed=579424 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=83.177ms
- Match 74 | seed=587343 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=92.042ms
- Match 75 | seed=595262 | outcome=draw | rounds=30 | replacements=0 | latency_p95=66.037ms
- Match 76 | seed=603181 | outcome=win(P1) | rounds=62 | replacements=0 | latency_p95=55.673ms
- Match 77 | seed=611100 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=64.308ms
- Match 78 | seed=619019 | outcome=draw | rounds=57 | replacements=0 | latency_p95=62.266ms
- Match 79 | seed=626938 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=57.164ms
- Match 80 | seed=634857 | outcome=win(P1) | rounds=58 | replacements=0 | latency_p95=53.316ms
- Match 81 | seed=642776 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=62.936ms
- Match 82 | seed=650695 | outcome=draw | rounds=32 | replacements=0 | latency_p95=79.412ms
- Match 83 | seed=658614 | outcome=win(P1) | rounds=5 | replacements=0 | latency_p95=44.573ms
- Match 84 | seed=666533 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=75.737ms
- Match 85 | seed=674452 | outcome=win(P2) | rounds=27 | replacements=0 | latency_p95=94.636ms
- Match 86 | seed=682371 | outcome=win(P2) | rounds=30 | replacements=0 | latency_p95=60.451ms
- Match 87 | seed=690290 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=46.501ms
- Match 88 | seed=698209 | outcome=win(P1) | rounds=75 | replacements=0 | latency_p95=64.584ms
- Match 89 | seed=706128 | outcome=win(P1) | rounds=10 | replacements=0 | latency_p95=71.325ms
- Match 90 | seed=714047 | outcome=draw | rounds=37 | replacements=0 | latency_p95=53.748ms
- Match 91 | seed=721966 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=87.331ms
- Match 92 | seed=729885 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=91.041ms
- Match 93 | seed=737804 | outcome=draw | rounds=47 | replacements=0 | latency_p95=86.082ms
- Match 94 | seed=745723 | outcome=win(P1) | rounds=26 | replacements=0 | latency_p95=86.362ms
- Match 95 | seed=753642 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=62.101ms
- Match 96 | seed=761561 | outcome=draw | rounds=22 | replacements=0 | latency_p95=48.790ms
- Match 97 | seed=769480 | outcome=draw | rounds=17 | replacements=0 | latency_p95=105.857ms
- Match 98 | seed=777399 | outcome=win(P2) | rounds=33 | replacements=0 | latency_p95=56.006ms
- Match 99 | seed=785318 | outcome=win(P1) | rounds=21 | replacements=0 | latency_p95=43.775ms
- Match 100 | seed=793237 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=65.838ms