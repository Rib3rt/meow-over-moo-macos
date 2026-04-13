# AI Strength Self-Play Report

- Generated: 2026-02-12 13:40:11
- Matches: 100
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `30` (30.00%)
- Player 2 wins: `37` (37.00%)
- Draws: `33` (33.00%)
- Avg rounds: `42.04`
- Decision latency median (ms): `10.304`
- Decision latency p95 (ms): `37.380`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 60
- `no_interaction_limit`: 32
- `opponent_no_units_or_supply`: 7
- `max_round_cap`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=9779 | P1=4979 | P2=4800
- `attack`: total=4585 | P1=2254 | P2=2331
- `supply_deploy`: total=1938 | P1=976 | P2=962
- `repair`: total=321 | P1=144 | P2=177
- `skip`: total=59 | P1=36 | P2=23

## Unit Usecase Stats

- `Cloudstriker`: total=4954 | P1=2501 | P2=2453 | supply_deploy=373 | move=3274 | attack=1307
- `Artillery`: total=2873 | P1=1454 | P2=1419 | supply_deploy=346 | move=1493 | attack=1034
- `Crusher`: total=2340 | P1=1173 | P2=1167 | supply_deploy=336 | move=1359 | attack=645
- `Bastion`: total=1752 | P1=904 | P2=848 | supply_deploy=173 | move=996 | attack=583
- `Wingstalker`: total=1713 | P1=867 | P2=846 | supply_deploy=283 | move=1030 | attack=400
- `Earthstalker`: total=1600 | P1=735 | P2=865 | supply_deploy=271 | move=956 | attack=373
- `Healer`: total=1391 | P1=719 | P2=672 | supply_deploy=156 | move=671 | attack=243 | repair=321
- `SKIP_SLOT`: total=59 | P1=36 | P2=23 | skip=59

## Match Rows

- Match 1 | seed=9256 | outcome=draw | rounds=62 | replacements=0 | latency_p95=52.495ms
- Match 2 | seed=17175 | outcome=draw | rounds=37 | replacements=0 | latency_p95=52.598ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=80 | replacements=0 | latency_p95=22.414ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=80 | replacements=0 | latency_p95=45.477ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=99 | replacements=0 | latency_p95=34.541ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=63 | replacements=0 | latency_p95=49.447ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=74 | replacements=0 | latency_p95=37.321ms
- Match 8 | seed=64689 | outcome=win(P2) | rounds=63 | replacements=0 | latency_p95=32.501ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=22 | replacements=0 | latency_p95=41.590ms
- Match 10 | seed=80527 | outcome=draw | rounds=28 | replacements=0 | latency_p95=31.547ms
- Match 11 | seed=88446 | outcome=win(P2) | rounds=76 | replacements=0 | latency_p95=41.567ms
- Match 12 | seed=96365 | outcome=draw | rounds=52 | replacements=0 | latency_p95=42.523ms
- Match 13 | seed=104284 | outcome=win(P2) | rounds=73 | replacements=0 | latency_p95=57.780ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=35.980ms
- Match 15 | seed=120122 | outcome=draw | rounds=19 | replacements=0 | latency_p95=22.823ms
- Match 16 | seed=128041 | outcome=draw | rounds=23 | replacements=0 | latency_p95=26.686ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=40.198ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=64 | replacements=0 | latency_p95=24.244ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=24.071ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=34 | replacements=0 | latency_p95=18.384ms
- Match 21 | seed=167636 | outcome=draw | rounds=42 | replacements=0 | latency_p95=34.364ms
- Match 22 | seed=175555 | outcome=draw | rounds=66 | replacements=0 | latency_p95=31.805ms
- Match 23 | seed=183474 | outcome=win(P1) | rounds=52 | replacements=0 | latency_p95=23.916ms
- Match 24 | seed=191393 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=36.666ms
- Match 25 | seed=199312 | outcome=win(P2) | rounds=20 | replacements=0 | latency_p95=21.071ms
- Match 26 | seed=207231 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=40.613ms
- Match 27 | seed=215150 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=49.862ms
- Match 28 | seed=223069 | outcome=win(P2) | rounds=78 | replacements=0 | latency_p95=31.739ms
- Match 29 | seed=230988 | outcome=draw | rounds=37 | replacements=0 | latency_p95=48.928ms
- Match 30 | seed=238907 | outcome=win(P1) | rounds=27 | replacements=0 | latency_p95=31.711ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=39.677ms
- Match 32 | seed=254745 | outcome=win(P2) | rounds=22 | replacements=0 | latency_p95=33.706ms
- Match 33 | seed=262664 | outcome=draw | rounds=19 | replacements=0 | latency_p95=48.538ms
- Match 34 | seed=270583 | outcome=win(P2) | rounds=41 | replacements=0 | latency_p95=22.118ms
- Match 35 | seed=278502 | outcome=draw | rounds=57 | replacements=0 | latency_p95=35.489ms
- Match 36 | seed=286421 | outcome=win(P1) | rounds=82 | replacements=0 | latency_p95=46.003ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=28 | replacements=0 | latency_p95=38.580ms
- Match 38 | seed=302259 | outcome=draw | rounds=40 | replacements=0 | latency_p95=34.092ms
- Match 39 | seed=310178 | outcome=draw | rounds=30 | replacements=0 | latency_p95=38.302ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=70 | replacements=0 | latency_p95=21.538ms
- Match 41 | seed=326016 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=37.480ms
- Match 42 | seed=333935 | outcome=win(P2) | rounds=57 | replacements=0 | latency_p95=27.456ms
- Match 43 | seed=341854 | outcome=draw | rounds=34 | replacements=0 | latency_p95=32.379ms
- Match 44 | seed=349773 | outcome=draw | rounds=34 | replacements=0 | latency_p95=35.203ms
- Match 45 | seed=357692 | outcome=draw | rounds=24 | replacements=0 | latency_p95=27.714ms
- Match 46 | seed=365611 | outcome=win(P2) | rounds=83 | replacements=0 | latency_p95=26.059ms
- Match 47 | seed=373530 | outcome=draw | rounds=24 | replacements=0 | latency_p95=45.475ms
- Match 48 | seed=381449 | outcome=win(P1) | rounds=41 | replacements=0 | latency_p95=42.803ms
- Match 49 | seed=389368 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=17.559ms
- Match 50 | seed=397287 | outcome=win(P1) | rounds=58 | replacements=0 | latency_p95=22.118ms
- Match 51 | seed=405206 | outcome=draw | rounds=37 | replacements=0 | latency_p95=27.452ms
- Match 52 | seed=413125 | outcome=win(P1) | rounds=61 | replacements=0 | latency_p95=34.921ms
- Match 53 | seed=421044 | outcome=win(P1) | rounds=21 | replacements=0 | latency_p95=31.438ms
- Match 54 | seed=428963 | outcome=draw | rounds=120 | replacements=0 | latency_p95=43.326ms
- Match 55 | seed=436882 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=19.511ms
- Match 56 | seed=444801 | outcome=win(P2) | rounds=66 | replacements=0 | latency_p95=40.196ms
- Match 57 | seed=452720 | outcome=win(P2) | rounds=48 | replacements=0 | latency_p95=55.795ms
- Match 58 | seed=460639 | outcome=draw | rounds=64 | replacements=0 | latency_p95=15.660ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=30.417ms
- Match 60 | seed=476477 | outcome=win(P1) | rounds=40 | replacements=0 | latency_p95=36.743ms
- Match 61 | seed=484396 | outcome=win(P2) | rounds=30 | replacements=0 | latency_p95=34.397ms
- Match 62 | seed=492315 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=38.838ms
- Match 63 | seed=500234 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=15.216ms
- Match 64 | seed=508153 | outcome=draw | rounds=27 | replacements=0 | latency_p95=42.721ms
- Match 65 | seed=516072 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=29.061ms
- Match 66 | seed=523991 | outcome=draw | rounds=53 | replacements=0 | latency_p95=61.678ms
- Match 67 | seed=531910 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=20.914ms
- Match 68 | seed=539829 | outcome=draw | rounds=47 | replacements=0 | latency_p95=31.962ms
- Match 69 | seed=547748 | outcome=win(P1) | rounds=36 | replacements=0 | latency_p95=26.708ms
- Match 70 | seed=555667 | outcome=draw | rounds=30 | replacements=0 | latency_p95=22.892ms
- Match 71 | seed=563586 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=19.108ms
- Match 72 | seed=571505 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=19.236ms
- Match 73 | seed=579424 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=59.718ms
- Match 74 | seed=587343 | outcome=win(P2) | rounds=86 | replacements=0 | latency_p95=41.444ms
- Match 75 | seed=595262 | outcome=draw | rounds=35 | replacements=0 | latency_p95=39.728ms
- Match 76 | seed=603181 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=27.919ms
- Match 77 | seed=611100 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=16.930ms
- Match 78 | seed=619019 | outcome=draw | rounds=36 | replacements=0 | latency_p95=56.463ms
- Match 79 | seed=626938 | outcome=draw | rounds=40 | replacements=0 | latency_p95=37.648ms
- Match 80 | seed=634857 | outcome=draw | rounds=27 | replacements=0 | latency_p95=32.637ms
- Match 81 | seed=642776 | outcome=draw | rounds=48 | replacements=0 | latency_p95=22.474ms
- Match 82 | seed=650695 | outcome=win(P2) | rounds=45 | replacements=0 | latency_p95=28.059ms
- Match 83 | seed=658614 | outcome=win(P2) | rounds=73 | replacements=0 | latency_p95=25.151ms
- Match 84 | seed=666533 | outcome=win(P1) | rounds=10 | replacements=0 | latency_p95=39.746ms
- Match 85 | seed=674452 | outcome=draw | rounds=79 | replacements=0 | latency_p95=46.815ms
- Match 86 | seed=682371 | outcome=draw | rounds=42 | replacements=0 | latency_p95=27.809ms
- Match 87 | seed=690290 | outcome=win(P1) | rounds=30 | replacements=0 | latency_p95=45.981ms
- Match 88 | seed=698209 | outcome=win(P2) | rounds=67 | replacements=0 | latency_p95=41.308ms
- Match 89 | seed=706128 | outcome=win(P1) | rounds=62 | replacements=0 | latency_p95=23.279ms
- Match 90 | seed=714047 | outcome=draw | rounds=57 | replacements=0 | latency_p95=18.054ms
- Match 91 | seed=721966 | outcome=win(P2) | rounds=105 | replacements=0 | latency_p95=42.959ms
- Match 92 | seed=729885 | outcome=win(P2) | rounds=11 | replacements=0 | latency_p95=23.251ms
- Match 93 | seed=737804 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=30.273ms
- Match 94 | seed=745723 | outcome=win(P1) | rounds=68 | replacements=0 | latency_p95=31.750ms
- Match 95 | seed=753642 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=32.999ms
- Match 96 | seed=761561 | outcome=win(P2) | rounds=58 | replacements=0 | latency_p95=30.819ms
- Match 97 | seed=769480 | outcome=win(P2) | rounds=34 | replacements=0 | latency_p95=36.916ms
- Match 98 | seed=777399 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=24.360ms
- Match 99 | seed=785318 | outcome=draw | rounds=33 | replacements=0 | latency_p95=26.000ms
- Match 100 | seed=793237 | outcome=win(P2) | rounds=54 | replacements=0 | latency_p95=21.232ms