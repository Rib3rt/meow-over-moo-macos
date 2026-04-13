# AI Strength Self-Play Report

- Generated: 2026-02-12 16:51:43
- Matches: 40
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `18` (45.00%)
- Player 2 wins: `16` (40.00%)
- Draws: `6` (15.00%)
- Avg rounds: `35.62`
- Decision latency median (ms): `18.414`
- Decision latency p95 (ms): `82.048`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 33
- `no_interaction_limit`: 6
- `opponent_no_units_or_supply`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=3512 | P1=1777 | P2=1735
- `attack`: total=1451 | P1=727 | P2=724
- `supply_deploy`: total=592 | P1=297 | P2=295
- `repair`: total=63 | P1=30 | P2=33
- `skip`: total=18 | P1=7 | P2=11

## Unit Usecase Stats

- `Cloudstriker`: total=1975 | P1=963 | P2=1012 | supply_deploy=147 | move=1307 | attack=521
- `Artillery`: total=941 | P1=498 | P2=443 | supply_deploy=115 | move=495 | attack=331
- `Crusher`: total=675 | P1=369 | P2=306 | supply_deploy=92 | move=423 | attack=160
- `Wingstalker`: total=590 | P1=325 | P2=265 | supply_deploy=83 | move=383 | attack=124
- `Bastion`: total=518 | P1=220 | P2=298 | supply_deploy=43 | move=337 | attack=138
- `Earthstalker`: total=510 | P1=245 | P2=265 | supply_deploy=65 | move=330 | attack=115
- `Healer`: total=409 | P1=211 | P2=198 | supply_deploy=47 | move=237 | attack=62 | repair=63
- `SKIP_SLOT`: total=18 | P1=7 | P2=11 | skip=18

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=110.947ms
- Match 2 | seed=17175 | outcome=win(P2) | rounds=40 | replacements=0 | latency_p95=73.401ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=36 | replacements=0 | latency_p95=45.726ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=43.000ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=38 | replacements=0 | latency_p95=91.694ms
- Match 6 | seed=48851 | outcome=win(P1) | rounds=87 | replacements=0 | latency_p95=73.327ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=21 | replacements=0 | latency_p95=64.429ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=33.863ms
- Match 9 | seed=72608 | outcome=win(P2) | rounds=78 | replacements=0 | latency_p95=128.786ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=62 | replacements=0 | latency_p95=70.054ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=77 | replacements=0 | latency_p95=68.983ms
- Match 12 | seed=96365 | outcome=win(P2) | rounds=17 | replacements=0 | latency_p95=70.204ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=106.943ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=79.562ms
- Match 15 | seed=120122 | outcome=win(P2) | rounds=109 | replacements=0 | latency_p95=100.953ms
- Match 16 | seed=128041 | outcome=win(P1) | rounds=77 | replacements=0 | latency_p95=85.137ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=82.615ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=31 | replacements=0 | latency_p95=49.993ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=79.253ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=37.920ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=43.810ms
- Match 22 | seed=175555 | outcome=draw | rounds=76 | replacements=0 | latency_p95=86.260ms
- Match 23 | seed=183474 | outcome=win(P1) | rounds=28 | replacements=0 | latency_p95=39.796ms
- Match 24 | seed=191393 | outcome=win(P2) | rounds=81 | replacements=0 | latency_p95=63.741ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=103.580ms
- Match 26 | seed=207231 | outcome=draw | rounds=53 | replacements=0 | latency_p95=71.421ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=38 | replacements=0 | latency_p95=60.499ms
- Match 28 | seed=223069 | outcome=win(P2) | rounds=70 | replacements=0 | latency_p95=90.184ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=63.815ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=58.191ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=39.116ms
- Match 32 | seed=254745 | outcome=win(P2) | rounds=36 | replacements=0 | latency_p95=98.088ms
- Match 33 | seed=262664 | outcome=draw | rounds=37 | replacements=0 | latency_p95=57.047ms
- Match 34 | seed=270583 | outcome=win(P1) | rounds=19 | replacements=0 | latency_p95=49.531ms
- Match 35 | seed=278502 | outcome=draw | rounds=47 | replacements=0 | latency_p95=119.242ms
- Match 36 | seed=286421 | outcome=draw | rounds=51 | replacements=0 | latency_p95=76.345ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=37 | replacements=0 | latency_p95=72.528ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=93.752ms
- Match 39 | seed=310178 | outcome=draw | rounds=41 | replacements=0 | latency_p95=87.370ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=53.945ms