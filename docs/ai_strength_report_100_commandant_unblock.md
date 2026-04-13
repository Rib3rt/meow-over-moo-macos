# AI Strength Self-Play Report

- Generated: 2026-02-12 13:52:01
- Matches: 100
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `36` (36.00%)
- Player 2 wins: `35` (35.00%)
- Draws: `29` (29.00%)
- Avg rounds: `32.34`
- Decision latency median (ms): `9.469`
- Decision latency p95 (ms): `36.584`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 68
- `no_interaction_limit`: 29
- `opponent_no_units_or_supply`: 3

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=7453 | P1=3774 | P2=3679
- `attack`: total=3533 | P1=1762 | P2=1771
- `supply_deploy`: total=1590 | P1=818 | P2=772
- `repair`: total=157 | P1=76 | P2=81
- `skip`: total=43 | P1=13 | P2=30

## Unit Usecase Stats

- `Cloudstriker`: total=4461 | P1=2268 | P2=2193 | supply_deploy=368 | move=2870 | attack=1223
- `Artillery`: total=2308 | P1=1121 | P2=1187 | supply_deploy=307 | move=1189 | attack=812
- `Crusher`: total=1480 | P1=781 | P2=699 | supply_deploy=240 | move=827 | attack=413
- `Wingstalker`: total=1299 | P1=645 | P2=654 | supply_deploy=217 | move=786 | attack=296
- `Earthstalker`: total=1184 | P1=566 | P2=618 | supply_deploy=205 | move=697 | attack=282
- `Bastion`: total=1088 | P1=560 | P2=528 | supply_deploy=118 | move=597 | attack=373
- `Healer`: total=913 | P1=489 | P2=424 | supply_deploy=135 | move=487 | attack=134 | repair=157
- `SKIP_SLOT`: total=43 | P1=13 | P2=30 | skip=43

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=38.121ms
- Match 2 | seed=17175 | outcome=draw | rounds=37 | replacements=0 | latency_p95=49.808ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=32 | replacements=0 | latency_p95=32.137ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=44.590ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=89 | replacements=0 | latency_p95=34.267ms
- Match 6 | seed=48851 | outcome=draw | rounds=15 | replacements=0 | latency_p95=20.136ms
- Match 7 | seed=56770 | outcome=draw | rounds=50 | replacements=0 | latency_p95=29.397ms
- Match 8 | seed=64689 | outcome=draw | rounds=36 | replacements=0 | latency_p95=26.982ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=27.025ms
- Match 10 | seed=80527 | outcome=draw | rounds=48 | replacements=0 | latency_p95=38.741ms
- Match 11 | seed=88446 | outcome=draw | rounds=42 | replacements=0 | latency_p95=20.928ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=38 | replacements=0 | latency_p95=47.794ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=26.966ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=27.547ms
- Match 15 | seed=120122 | outcome=draw | rounds=19 | replacements=0 | latency_p95=22.833ms
- Match 16 | seed=128041 | outcome=draw | rounds=23 | replacements=0 | latency_p95=25.424ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=40.658ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=67 | replacements=0 | latency_p95=41.083ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=25.057ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=21.146ms
- Match 21 | seed=167636 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=31.453ms
- Match 22 | seed=175555 | outcome=win(P2) | rounds=76 | replacements=0 | latency_p95=27.863ms
- Match 23 | seed=183474 | outcome=win(P1) | rounds=45 | replacements=0 | latency_p95=29.725ms
- Match 24 | seed=191393 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=35.040ms
- Match 25 | seed=199312 | outcome=draw | rounds=31 | replacements=0 | latency_p95=31.506ms
- Match 26 | seed=207231 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=18.394ms
- Match 27 | seed=215150 | outcome=win(P1) | rounds=74 | replacements=0 | latency_p95=25.345ms
- Match 28 | seed=223069 | outcome=draw | rounds=26 | replacements=0 | latency_p95=37.423ms
- Match 29 | seed=230988 | outcome=win(P2) | rounds=16 | replacements=0 | latency_p95=35.458ms
- Match 30 | seed=238907 | outcome=win(P1) | rounds=74 | replacements=0 | latency_p95=128.398ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=25.231ms
- Match 32 | seed=254745 | outcome=win(P2) | rounds=22 | replacements=0 | latency_p95=55.745ms
- Match 33 | seed=262664 | outcome=draw | rounds=19 | replacements=0 | latency_p95=46.917ms
- Match 34 | seed=270583 | outcome=win(P2) | rounds=11 | replacements=0 | latency_p95=25.283ms
- Match 35 | seed=278502 | outcome=win(P2) | rounds=76 | replacements=0 | latency_p95=29.768ms
- Match 36 | seed=286421 | outcome=win(P1) | rounds=88 | replacements=0 | latency_p95=50.223ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=43 | replacements=0 | latency_p95=30.862ms
- Match 38 | seed=302259 | outcome=draw | rounds=24 | replacements=0 | latency_p95=29.419ms
- Match 39 | seed=310178 | outcome=win(P1) | rounds=59 | replacements=0 | latency_p95=32.316ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=11 | replacements=0 | latency_p95=20.953ms
- Match 41 | seed=326016 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=45.369ms
- Match 42 | seed=333935 | outcome=win(P2) | rounds=11 | replacements=0 | latency_p95=36.918ms
- Match 43 | seed=341854 | outcome=draw | rounds=24 | replacements=0 | latency_p95=34.615ms
- Match 44 | seed=349773 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=56.836ms
- Match 45 | seed=357692 | outcome=win(P2) | rounds=72 | replacements=0 | latency_p95=24.473ms
- Match 46 | seed=365611 | outcome=draw | rounds=49 | replacements=0 | latency_p95=16.295ms
- Match 47 | seed=373530 | outcome=draw | rounds=23 | replacements=0 | latency_p95=33.291ms
- Match 48 | seed=381449 | outcome=win(P1) | rounds=34 | replacements=0 | latency_p95=10.817ms
- Match 49 | seed=389368 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=15.207ms
- Match 50 | seed=397287 | outcome=draw | rounds=36 | replacements=0 | latency_p95=22.183ms
- Match 51 | seed=405206 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=27.490ms
- Match 52 | seed=413125 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=14.410ms
- Match 53 | seed=421044 | outcome=win(P2) | rounds=59 | replacements=0 | latency_p95=32.189ms
- Match 54 | seed=428963 | outcome=win(P1) | rounds=10 | replacements=0 | latency_p95=61.306ms
- Match 55 | seed=436882 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=17.364ms
- Match 56 | seed=444801 | outcome=win(P2) | rounds=31 | replacements=0 | latency_p95=43.516ms
- Match 57 | seed=452720 | outcome=win(P1) | rounds=64 | replacements=0 | latency_p95=31.729ms
- Match 58 | seed=460639 | outcome=draw | rounds=37 | replacements=0 | latency_p95=15.452ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=25.729ms
- Match 60 | seed=476477 | outcome=draw | rounds=49 | replacements=0 | latency_p95=22.639ms
- Match 61 | seed=484396 | outcome=draw | rounds=34 | replacements=0 | latency_p95=27.538ms
- Match 62 | seed=492315 | outcome=win(P2) | rounds=6 | replacements=0 | latency_p95=29.059ms
- Match 63 | seed=500234 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=19.186ms
- Match 64 | seed=508153 | outcome=win(P2) | rounds=24 | replacements=0 | latency_p95=39.391ms
- Match 65 | seed=516072 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=33.785ms
- Match 66 | seed=523991 | outcome=draw | rounds=53 | replacements=0 | latency_p95=63.358ms
- Match 67 | seed=531910 | outcome=win(P1) | rounds=62 | replacements=0 | latency_p95=41.005ms
- Match 68 | seed=539829 | outcome=win(P1) | rounds=65 | replacements=0 | latency_p95=29.434ms
- Match 69 | seed=547748 | outcome=draw | rounds=35 | replacements=0 | latency_p95=35.894ms
- Match 70 | seed=555667 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=41.540ms
- Match 71 | seed=563586 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=19.503ms
- Match 72 | seed=571505 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=19.798ms
- Match 73 | seed=579424 | outcome=win(P2) | rounds=24 | replacements=0 | latency_p95=33.894ms
- Match 74 | seed=587343 | outcome=draw | rounds=24 | replacements=0 | latency_p95=38.736ms
- Match 75 | seed=595262 | outcome=draw | rounds=27 | replacements=0 | latency_p95=45.474ms
- Match 76 | seed=603181 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=31.490ms
- Match 77 | seed=611100 | outcome=win(P1) | rounds=44 | replacements=0 | latency_p95=22.338ms
- Match 78 | seed=619019 | outcome=draw | rounds=36 | replacements=0 | latency_p95=56.526ms
- Match 79 | seed=626938 | outcome=draw | rounds=40 | replacements=0 | latency_p95=45.718ms
- Match 80 | seed=634857 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=33.561ms
- Match 81 | seed=642776 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=27.825ms
- Match 82 | seed=650695 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=26.752ms
- Match 83 | seed=658614 | outcome=win(P1) | rounds=5 | replacements=0 | latency_p95=20.658ms
- Match 84 | seed=666533 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=36.375ms
- Match 85 | seed=674452 | outcome=draw | rounds=35 | replacements=0 | latency_p95=26.385ms
- Match 86 | seed=682371 | outcome=win(P1) | rounds=51 | replacements=0 | latency_p95=35.228ms
- Match 87 | seed=690290 | outcome=draw | rounds=17 | replacements=0 | latency_p95=32.699ms
- Match 88 | seed=698209 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=19.594ms
- Match 89 | seed=706128 | outcome=win(P2) | rounds=19 | replacements=0 | latency_p95=28.677ms
- Match 90 | seed=714047 | outcome=win(P1) | rounds=75 | replacements=0 | latency_p95=44.385ms
- Match 91 | seed=721966 | outcome=win(P2) | rounds=40 | replacements=0 | latency_p95=25.740ms
- Match 92 | seed=729885 | outcome=draw | rounds=47 | replacements=0 | latency_p95=25.123ms
- Match 93 | seed=737804 | outcome=win(P2) | rounds=62 | replacements=0 | latency_p95=36.018ms
- Match 94 | seed=745723 | outcome=win(P1) | rounds=68 | replacements=0 | latency_p95=32.479ms
- Match 95 | seed=753642 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=52.441ms
- Match 96 | seed=761561 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=21.149ms
- Match 97 | seed=769480 | outcome=win(P2) | rounds=34 | replacements=0 | latency_p95=37.594ms
- Match 98 | seed=777399 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=32.100ms
- Match 99 | seed=785318 | outcome=draw | rounds=51 | replacements=0 | latency_p95=21.072ms
- Match 100 | seed=793237 | outcome=win(P1) | rounds=62 | replacements=0 | latency_p95=29.770ms