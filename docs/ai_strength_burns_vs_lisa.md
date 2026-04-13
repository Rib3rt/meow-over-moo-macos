# AI Strength Self-Play Report

- Generated: 2026-02-20 12:00:41
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `base`
- Player 2 reference: `burns`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `7` (35.00%)
- Player 2 wins: `13` (65.00%)
- Draws: `0` (0.00%)
- Avg rounds: `57.65`
- Decision latency median (ms): `120.285`
- Decision latency p95 (ms): `932.256`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `opponent_no_units_or_supply`: 14
- `commandant_destroyed`: 6

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2356 | P1=1193 | P2=1163
- `attack`: total=1523 | P1=739 | P2=784
- `supply_deploy`: total=553 | P1=278 | P2=275
- `repair`: total=103 | P1=60 | P2=43
- `skip`: total=51 | P1=31 | P2=20

## Unit Usecase Stats

- `Crusher`: total=925 | P1=478 | P2=447 | supply_deploy=118 | move=506 | attack=301
- `Bastion`: total=806 | P1=382 | P2=424 | supply_deploy=79 | move=430 | attack=297
- `Artillery`: total=784 | P1=347 | P2=437 | supply_deploy=80 | move=380 | attack=324
- `Cloudstriker`: total=650 | P1=346 | P2=304 | supply_deploy=80 | move=337 | attack=233
- `Earthstalker`: total=550 | P1=291 | P2=259 | supply_deploy=80 | move=287 | attack=183
- `Wingstalker`: total=478 | P1=230 | P2=248 | supply_deploy=80 | move=262 | attack=136
- `Healer`: total=342 | P1=196 | P2=146 | supply_deploy=36 | move=154 | attack=49 | repair=103
- `SKIP_SLOT`: total=51 | P1=31 | P2=20 | skip=51

## Match Rows

- Match 1 | seed=9256 | outcome=win(P1) | rounds=67 | replacements=0 | latency_p95=1078.101ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=812.689ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=65 | replacements=0 | latency_p95=672.153ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=55 | replacements=0 | latency_p95=810.524ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=66 | replacements=0 | latency_p95=1287.393ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=51 | replacements=0 | latency_p95=858.201ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=943.109ms
- Match 8 | seed=64689 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=499.090ms
- Match 9 | seed=72608 | outcome=win(P2) | rounds=68 | replacements=0 | latency_p95=1179.067ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=50 | replacements=0 | latency_p95=1026.170ms
- Match 11 | seed=88446 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=634.710ms
- Match 12 | seed=96365 | outcome=win(P2) | rounds=61 | replacements=0 | latency_p95=1125.515ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=52 | replacements=0 | latency_p95=754.288ms
- Match 14 | seed=112203 | outcome=win(P2) | rounds=52 | replacements=0 | latency_p95=511.726ms
- Match 15 | seed=120122 | outcome=win(P1) | rounds=58 | replacements=0 | latency_p95=789.232ms
- Match 16 | seed=128041 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=1202.448ms
- Match 17 | seed=135960 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=1033.090ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=496.925ms
- Match 19 | seed=151798 | outcome=win(P1) | rounds=56 | replacements=0 | latency_p95=931.453ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=52 | replacements=0 | latency_p95=696.142ms