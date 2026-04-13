# AI Strength Self-Play Report

- Generated: 2026-02-20 12:14:44
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `burns`
- Player 2 reference: `burns`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `8` (40.00%)
- Player 2 wins: `11` (55.00%)
- Draws: `1` (5.00%)
- Avg rounds: `57.85`
- Decision latency median (ms): `163.940`
- Decision latency p95 (ms): `851.786`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 10
- `opponent_no_units_or_supply`: 9
- `max_round_cap`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2246 | P1=1206 | P2=1040
- `attack`: total=1606 | P1=670 | P2=936
- `supply_deploy`: total=528 | P1=266 | P2=262
- `repair`: total=169 | P1=137 | P2=32
- `skip`: total=54 | P1=31 | P2=23

## Unit Usecase Stats

- `Bastion`: total=858 | P1=423 | P2=435 | supply_deploy=77 | move=433 | attack=348
- `Crusher`: total=856 | P1=449 | P2=407 | supply_deploy=106 | move=473 | attack=277
- `Artillery`: total=846 | P1=356 | P2=490 | supply_deploy=80 | move=347 | attack=419
- `Cloudstriker`: total=661 | P1=344 | P2=317 | supply_deploy=80 | move=342 | attack=239
- `Earthstalker`: total=490 | P1=255 | P2=235 | supply_deploy=75 | move=261 | attack=154
- `Wingstalker`: total=479 | P1=237 | P2=242 | supply_deploy=79 | move=276 | attack=124
- `Healer`: total=359 | P1=215 | P2=144 | supply_deploy=31 | move=114 | attack=45 | repair=169
- `SKIP_SLOT`: total=54 | P1=31 | P2=23 | skip=54

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=52 | replacements=0 | latency_p95=1010.308ms
- Match 2 | seed=17175 | outcome=win(P2) | rounds=74 | replacements=0 | latency_p95=1028.363ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=66 | replacements=0 | latency_p95=741.194ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=37 | replacements=0 | latency_p95=936.633ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=1731.769ms
- Match 6 | seed=48851 | outcome=win(P1) | rounds=64 | replacements=0 | latency_p95=1037.004ms
- Match 7 | seed=56770 | outcome=win(P1) | rounds=72 | replacements=0 | latency_p95=926.475ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=46 | replacements=0 | latency_p95=702.716ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=54 | replacements=0 | latency_p95=817.942ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=47 | replacements=0 | latency_p95=890.644ms
- Match 11 | seed=88446 | outcome=win(P2) | rounds=66 | replacements=0 | latency_p95=773.827ms
- Match 12 | seed=96365 | outcome=win(P2) | rounds=61 | replacements=0 | latency_p95=788.454ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=64 | replacements=0 | latency_p95=924.379ms
- Match 14 | seed=112203 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=804.915ms
- Match 15 | seed=120122 | outcome=win(P1) | rounds=57 | replacements=0 | latency_p95=880.496ms
- Match 16 | seed=128041 | outcome=draw | rounds=120 | replacements=0 | latency_p95=749.055ms
- Match 17 | seed=135960 | outcome=win(P2) | rounds=51 | replacements=0 | latency_p95=747.710ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=49 | replacements=0 | latency_p95=737.300ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=19 | replacements=0 | latency_p95=1338.867ms
- Match 20 | seed=159717 | outcome=win(P2) | rounds=50 | replacements=0 | latency_p95=529.826ms