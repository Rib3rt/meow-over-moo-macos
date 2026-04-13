# AI Strength Self-Play Report

- Generated: 2026-02-20 18:26:23
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `base`
- Player 2 reference: `base`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `11` (55.00%)
- Player 2 wins: `9` (45.00%)
- Draws: `0` (0.00%)
- Avg rounds: `57.05`
- Decision latency median (ms): `81.683`
- Decision latency p95 (ms): `593.730`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `opponent_no_units_or_supply`: 15
- `commandant_destroyed`: 5

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2356 | P1=1160 | P2=1196
- `attack`: total=1494 | P1=780 | P2=714
- `supply_deploy`: total=552 | P1=274 | P2=278
- `repair`: total=81 | P1=37 | P2=44
- `skip`: total=50 | P1=27 | P2=23

## Unit Usecase Stats

- `Crusher`: total=969 | P1=465 | P2=504 | supply_deploy=117 | move=544 | attack=308
- `Artillery`: total=842 | P1=431 | P2=411 | supply_deploy=80 | move=406 | attack=356
- `Bastion`: total=666 | P1=340 | P2=326 | supply_deploy=79 | move=365 | attack=222
- `Cloudstriker`: total=634 | P1=331 | P2=303 | supply_deploy=80 | move=309 | attack=245
- `Earthstalker`: total=588 | P1=296 | P2=292 | supply_deploy=79 | move=332 | attack=177
- `Wingstalker`: total=540 | P1=284 | P2=256 | supply_deploy=80 | move=295 | attack=165
- `Healer`: total=244 | P1=104 | P2=140 | supply_deploy=37 | move=105 | attack=21 | repair=81
- `SKIP_SLOT`: total=50 | P1=27 | P2=23 | skip=50

## Match Rows

- Match 1 | seed=9256 | outcome=win(P1) | rounds=44 | replacements=0 | latency_p95=1030.160ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=61 | replacements=0 | latency_p95=558.291ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=553.861ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=51 | replacements=0 | latency_p95=538.210ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=80 | replacements=0 | latency_p95=934.603ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=645.797ms
- Match 7 | seed=56770 | outcome=win(P1) | rounds=47 | replacements=0 | latency_p95=615.349ms
- Match 8 | seed=64689 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=505.777ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=64 | replacements=0 | latency_p95=496.103ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=47 | replacements=0 | latency_p95=607.029ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=49 | replacements=0 | latency_p95=575.435ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=51 | replacements=0 | latency_p95=588.128ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=63 | replacements=0 | latency_p95=535.679ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=49 | replacements=0 | latency_p95=437.950ms
- Match 15 | seed=120122 | outcome=win(P2) | rounds=65 | replacements=0 | latency_p95=580.008ms
- Match 16 | seed=128041 | outcome=win(P2) | rounds=68 | replacements=0 | latency_p95=721.555ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=62 | replacements=0 | latency_p95=466.056ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=60 | replacements=0 | latency_p95=765.274ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=63 | replacements=0 | latency_p95=849.356ms
- Match 20 | seed=159717 | outcome=win(P2) | rounds=40 | replacements=0 | latency_p95=465.674ms