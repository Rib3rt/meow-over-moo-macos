# AI Strength Self-Play Report

- Generated: 2026-02-12 18:20:28
- Matches: 100
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `39` (39.00%)
- Player 2 wins: `38` (38.00%)
- Draws: `23` (23.00%)
- Avg rounds: `49.35`
- Decision latency median (ms): `24.612`
- Decision latency p95 (ms): `114.021`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 67
- `no_interaction_limit`: 22
- `opponent_no_units_or_supply`: 10
- `max_round_cap`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=11745 | P1=5924 | P2=5821
- `attack`: total=5198 | P1=2522 | P2=2676
- `supply_deploy`: total=2100 | P1=1057 | P2=1043
- `repair`: total=459 | P1=301 | P2=158
- `skip`: total=87 | P1=37 | P2=50

## Unit Usecase Stats

- `Cloudstriker`: total=5980 | P1=3058 | P2=2922 | supply_deploy=392 | move=3808 | attack=1780
- `Artillery`: total=3156 | P1=1558 | P2=1598 | supply_deploy=358 | move=1632 | attack=1166
- `Crusher`: total=3010 | P1=1499 | P2=1511 | supply_deploy=379 | move=1891 | attack=740
- `Wingstalker`: total=2165 | P1=1053 | P2=1112 | supply_deploy=312 | move=1444 | attack=409
- `Bastion`: total=1910 | P1=915 | P2=995 | supply_deploy=201 | move=1174 | attack=535
- `Earthstalker`: total=1736 | P1=854 | P2=882 | supply_deploy=289 | move=1096 | attack=351
- `Healer`: total=1545 | P1=867 | P2=678 | supply_deploy=169 | move=700 | attack=217 | repair=459
- `SKIP_SLOT`: total=87 | P1=37 | P2=50 | skip=87

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=13 | replacements=0 | latency_p95=101.546ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=66 | replacements=0 | latency_p95=250.955ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=57.810ms
- Match 4 | seed=33013 | outcome=draw | rounds=28 | replacements=0 | latency_p95=107.398ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=67.147ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=145.171ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=70 | replacements=0 | latency_p95=105.376ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=35 | replacements=0 | latency_p95=54.633ms
- Match 9 | seed=72608 | outcome=draw | rounds=48 | replacements=0 | latency_p95=163.968ms
- Match 10 | seed=80527 | outcome=win(P1) | rounds=68 | replacements=0 | latency_p95=124.406ms
- Match 11 | seed=88446 | outcome=draw | rounds=26 | replacements=0 | latency_p95=179.994ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=72.775ms
- Match 13 | seed=104284 | outcome=draw | rounds=39 | replacements=0 | latency_p95=169.895ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=96.929ms
- Match 15 | seed=120122 | outcome=win(P1) | rounds=87 | replacements=0 | latency_p95=111.559ms
- Match 16 | seed=128041 | outcome=draw | rounds=41 | replacements=0 | latency_p95=72.704ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=20 | replacements=0 | latency_p95=122.606ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=64.823ms
- Match 19 | seed=151798 | outcome=win(P1) | rounds=83 | replacements=0 | latency_p95=116.595ms
- Match 20 | seed=159717 | outcome=draw | rounds=56 | replacements=0 | latency_p95=95.027ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=49.162ms
- Match 22 | seed=175555 | outcome=win(P1) | rounds=80 | replacements=0 | latency_p95=158.682ms
- Match 23 | seed=183474 | outcome=draw | rounds=34 | replacements=0 | latency_p95=67.890ms
- Match 24 | seed=191393 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=51.632ms
- Match 25 | seed=199312 | outcome=draw | rounds=29 | replacements=0 | latency_p95=106.086ms
- Match 26 | seed=207231 | outcome=win(P1) | rounds=22 | replacements=0 | latency_p95=88.125ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=16 | replacements=0 | latency_p95=57.104ms
- Match 28 | seed=223069 | outcome=win(P2) | rounds=68 | replacements=0 | latency_p95=101.261ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=60 | replacements=0 | latency_p95=179.393ms
- Match 30 | seed=238907 | outcome=draw | rounds=23 | replacements=0 | latency_p95=77.594ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=63.538ms
- Match 32 | seed=254745 | outcome=win(P2) | rounds=83 | replacements=0 | latency_p95=202.709ms
- Match 33 | seed=262664 | outcome=draw | rounds=53 | replacements=0 | latency_p95=91.454ms
- Match 34 | seed=270583 | outcome=win(P2) | rounds=5 | replacements=0 | latency_p95=32.231ms
- Match 35 | seed=278502 | outcome=win(P2) | rounds=68 | replacements=0 | latency_p95=192.083ms
- Match 36 | seed=286421 | outcome=win(P2) | rounds=49 | replacements=0 | latency_p95=91.523ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=30 | replacements=0 | latency_p95=82.347ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=72 | replacements=0 | latency_p95=120.578ms
- Match 39 | seed=310178 | outcome=win(P2) | rounds=91 | replacements=0 | latency_p95=111.652ms
- Match 40 | seed=318097 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=94.282ms
- Match 41 | seed=326016 | outcome=win(P1) | rounds=73 | replacements=0 | latency_p95=154.115ms
- Match 42 | seed=333935 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=30.342ms
- Match 43 | seed=341854 | outcome=win(P1) | rounds=81 | replacements=0 | latency_p95=100.844ms
- Match 44 | seed=349773 | outcome=win(P1) | rounds=87 | replacements=0 | latency_p95=127.982ms
- Match 45 | seed=357692 | outcome=win(P2) | rounds=68 | replacements=0 | latency_p95=109.624ms
- Match 46 | seed=365611 | outcome=draw | rounds=58 | replacements=0 | latency_p95=108.251ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=89 | replacements=0 | latency_p95=135.117ms
- Match 48 | seed=381449 | outcome=win(P2) | rounds=65 | replacements=0 | latency_p95=114.614ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=35 | replacements=0 | latency_p95=63.634ms
- Match 50 | seed=397287 | outcome=win(P1) | rounds=58 | replacements=0 | latency_p95=94.594ms
- Match 51 | seed=405206 | outcome=win(P1) | rounds=23 | replacements=0 | latency_p95=96.185ms
- Match 52 | seed=413125 | outcome=win(P2) | rounds=73 | replacements=0 | latency_p95=84.122ms
- Match 53 | seed=421044 | outcome=win(P2) | rounds=52 | replacements=0 | latency_p95=88.073ms
- Match 54 | seed=428963 | outcome=win(P2) | rounds=73 | replacements=0 | latency_p95=88.504ms
- Match 55 | seed=436882 | outcome=win(P2) | rounds=42 | replacements=0 | latency_p95=60.406ms
- Match 56 | seed=444801 | outcome=win(P2) | rounds=50 | replacements=0 | latency_p95=116.091ms
- Match 57 | seed=452720 | outcome=win(P1) | rounds=54 | replacements=0 | latency_p95=90.502ms
- Match 58 | seed=460639 | outcome=draw | rounds=35 | replacements=0 | latency_p95=55.171ms
- Match 59 | seed=468558 | outcome=win(P1) | rounds=11 | replacements=0 | latency_p95=80.007ms
- Match 60 | seed=476477 | outcome=win(P1) | rounds=33 | replacements=0 | latency_p95=87.526ms
- Match 61 | seed=484396 | outcome=win(P2) | rounds=39 | replacements=0 | latency_p95=159.244ms
- Match 62 | seed=492315 | outcome=win(P2) | rounds=67 | replacements=0 | latency_p95=96.006ms
- Match 63 | seed=500234 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=202.570ms
- Match 64 | seed=508153 | outcome=win(P2) | rounds=98 | replacements=0 | latency_p95=104.303ms
- Match 65 | seed=516072 | outcome=win(P2) | rounds=46 | replacements=0 | latency_p95=76.218ms
- Match 66 | seed=523991 | outcome=draw | rounds=26 | replacements=0 | latency_p95=53.549ms
- Match 67 | seed=531910 | outcome=draw | rounds=30 | replacements=0 | latency_p95=139.683ms
- Match 68 | seed=539829 | outcome=draw | rounds=45 | replacements=0 | latency_p95=91.993ms
- Match 69 | seed=547748 | outcome=win(P1) | rounds=62 | replacements=0 | latency_p95=106.186ms
- Match 70 | seed=555667 | outcome=win(P2) | rounds=80 | replacements=0 | latency_p95=68.140ms
- Match 71 | seed=563586 | outcome=win(P1) | rounds=71 | replacements=0 | latency_p95=61.908ms
- Match 72 | seed=571505 | outcome=win(P1) | rounds=41 | replacements=0 | latency_p95=149.429ms
- Match 73 | seed=579424 | outcome=win(P2) | rounds=86 | replacements=0 | latency_p95=112.888ms
- Match 74 | seed=587343 | outcome=win(P1) | rounds=34 | replacements=0 | latency_p95=112.746ms
- Match 75 | seed=595262 | outcome=draw | rounds=35 | replacements=0 | latency_p95=67.029ms
- Match 76 | seed=603181 | outcome=win(P2) | rounds=22 | replacements=0 | latency_p95=75.729ms
- Match 77 | seed=611100 | outcome=win(P1) | rounds=34 | replacements=0 | latency_p95=59.317ms
- Match 78 | seed=619019 | outcome=draw | rounds=33 | replacements=0 | latency_p95=109.112ms
- Match 79 | seed=626938 | outcome=win(P2) | rounds=61 | replacements=0 | latency_p95=90.073ms
- Match 80 | seed=634857 | outcome=draw | rounds=65 | replacements=0 | latency_p95=77.762ms
- Match 81 | seed=642776 | outcome=win(P1) | rounds=72 | replacements=0 | latency_p95=68.717ms
- Match 82 | seed=650695 | outcome=draw | rounds=42 | replacements=0 | latency_p95=68.718ms
- Match 83 | seed=658614 | outcome=draw | rounds=53 | replacements=0 | latency_p95=212.005ms
- Match 84 | seed=666533 | outcome=win(P2) | rounds=75 | replacements=0 | latency_p95=119.255ms
- Match 85 | seed=674452 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=81.138ms
- Match 86 | seed=682371 | outcome=draw | rounds=39 | replacements=0 | latency_p95=84.127ms
- Match 87 | seed=690290 | outcome=win(P2) | rounds=67 | replacements=0 | latency_p95=75.239ms
- Match 88 | seed=698209 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=37.893ms
- Match 89 | seed=706128 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=54.294ms
- Match 90 | seed=714047 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=76.989ms
- Match 91 | seed=721966 | outcome=draw | rounds=57 | replacements=0 | latency_p95=98.423ms
- Match 92 | seed=729885 | outcome=win(P1) | rounds=75 | replacements=0 | latency_p95=106.628ms
- Match 93 | seed=737804 | outcome=win(P2) | rounds=72 | replacements=0 | latency_p95=101.489ms
- Match 94 | seed=745723 | outcome=win(P1) | rounds=74 | replacements=0 | latency_p95=99.553ms
- Match 95 | seed=753642 | outcome=win(P2) | rounds=7 | replacements=0 | latency_p95=79.834ms
- Match 96 | seed=761561 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=85.165ms
- Match 97 | seed=769480 | outcome=draw | rounds=120 | replacements=0 | latency_p95=430.387ms
- Match 98 | seed=777399 | outcome=win(P1) | rounds=69 | replacements=0 | latency_p95=91.537ms
- Match 99 | seed=785318 | outcome=win(P2) | rounds=81 | replacements=0 | latency_p95=97.832ms
- Match 100 | seed=793237 | outcome=win(P1) | rounds=31 | replacements=0 | latency_p95=78.736ms