# AI Strength Self-Play Report

- Generated: 2026-02-19 15:21:24
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `4` (20.00%)
- Player 2 wins: `6` (30.00%)
- Draws: `10` (50.00%)
- Avg rounds: `37.00`
- Decision latency median (ms): `78.002`
- Decision latency p95 (ms): `687.648`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `no_interaction_limit`: 10
- `commandant_destroyed`: 7
- `opponent_no_units_or_supply`: 3

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=1412 | P1=708 | P2=704
- `attack`: total=945 | P1=476 | P2=469
- `supply_deploy`: total=504 | P1=260 | P2=244
- `repair`: total=61 | P1=27 | P2=34
- `skip`: total=17 | P1=7 | P2=10

## Unit Usecase Stats

- `Cloudstriker`: total=737 | P1=366 | P2=371 | supply_deploy=80 | move=351 | attack=306
- `Artillery`: total=487 | P1=259 | P2=228 | supply_deploy=79 | move=207 | attack=201
- `Crusher`: total=459 | P1=208 | P2=251 | supply_deploy=94 | move=216 | attack=149
- `Bastion`: total=438 | P1=237 | P2=201 | supply_deploy=74 | move=212 | attack=152
- `Wingstalker`: total=379 | P1=185 | P2=194 | supply_deploy=79 | move=226 | attack=74
- `Earthstalker`: total=257 | P1=128 | P2=129 | supply_deploy=75 | move=133 | attack=49
- `Healer`: total=165 | P1=88 | P2=77 | supply_deploy=23 | move=67 | attack=14 | repair=61
- `SKIP_SLOT`: total=17 | P1=7 | P2=10 | skip=17

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=59 | replacements=0 | latency_p95=1410.984ms
- Match 2 | seed=17175 | outcome=draw | rounds=21 | replacements=0 | latency_p95=213.035ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=65 | replacements=0 | latency_p95=544.112ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=48 | replacements=0 | latency_p95=1019.742ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=907.721ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=28 | replacements=0 | latency_p95=1457.692ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=48 | replacements=0 | latency_p95=1115.417ms
- Match 8 | seed=64689 | outcome=draw | rounds=48 | replacements=0 | latency_p95=802.723ms
- Match 9 | seed=72608 | outcome=draw | rounds=22 | replacements=0 | latency_p95=606.982ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=368.222ms
- Match 11 | seed=88446 | outcome=draw | rounds=38 | replacements=0 | latency_p95=566.977ms
- Match 12 | seed=96365 | outcome=draw | rounds=29 | replacements=0 | latency_p95=717.723ms
- Match 13 | seed=104284 | outcome=draw | rounds=22 | replacements=0 | latency_p95=479.360ms
- Match 14 | seed=112203 | outcome=win(P2) | rounds=33 | replacements=0 | latency_p95=478.926ms
- Match 15 | seed=120122 | outcome=draw | rounds=20 | replacements=0 | latency_p95=347.494ms
- Match 16 | seed=128041 | outcome=draw | rounds=21 | replacements=0 | latency_p95=177.256ms
- Match 17 | seed=135960 | outcome=draw | rounds=15 | replacements=0 | latency_p95=447.655ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=46 | replacements=0 | latency_p95=302.577ms
- Match 19 | seed=151798 | outcome=draw | rounds=21 | replacements=0 | latency_p95=417.310ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=48 | replacements=0 | latency_p95=631.788ms