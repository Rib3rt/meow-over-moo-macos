# AI Strength Self-Play Report

- Generated: 2026-02-20 09:39:12
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `base`
- Player 2 reference: `burt`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `9` (45.00%)
- Player 2 wins: `10` (50.00%)
- Draws: `1` (5.00%)
- Avg rounds: `57.00`
- Decision latency median (ms): `70.530`
- Decision latency p95 (ms): `536.187`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `opponent_no_units_or_supply`: 14
- `commandant_destroyed`: 5
- `max_round_cap`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2327 | P1=1168 | P2=1159
- `attack`: total=1526 | P1=740 | P2=786
- `supply_deploy`: total=531 | P1=269 | P2=262
- `repair`: total=113 | P1=79 | P2=34
- `skip`: total=34 | P1=19 | P2=15

## Unit Usecase Stats

- `Crusher`: total=924 | P1=458 | P2=466 | supply_deploy=112 | move=522 | attack=290
- `Bastion`: total=832 | P1=362 | P2=470 | supply_deploy=76 | move=421 | attack=335
- `Cloudstriker`: total=681 | P1=351 | P2=330 | supply_deploy=80 | move=336 | attack=265
- `Artillery`: total=649 | P1=343 | P2=306 | supply_deploy=78 | move=312 | attack=259
- `Earthstalker`: total=583 | P1=235 | P2=348 | supply_deploy=76 | move=330 | attack=177
- `Wingstalker`: total=478 | P1=248 | P2=230 | supply_deploy=78 | move=261 | attack=139
- `Healer`: total=350 | P1=259 | P2=91 | supply_deploy=31 | move=145 | attack=61 | repair=113
- `SKIP_SLOT`: total=34 | P1=19 | P2=15 | skip=34

## Match Rows

- Match 1 | seed=9256 | outcome=win(P1) | rounds=52 | replacements=0 | latency_p95=445.863ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=69 | replacements=0 | latency_p95=589.169ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=61 | replacements=0 | latency_p95=378.047ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=60 | replacements=0 | latency_p95=667.585ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=45 | replacements=0 | latency_p95=673.419ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=484.620ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=54 | replacements=0 | latency_p95=487.573ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=56 | replacements=0 | latency_p95=412.523ms
- Match 9 | seed=72608 | outcome=win(P2) | rounds=60 | replacements=0 | latency_p95=470.719ms
- Match 10 | seed=80527 | outcome=win(P1) | rounds=58 | replacements=0 | latency_p95=577.662ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=50 | replacements=0 | latency_p95=460.475ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=46 | replacements=0 | latency_p95=502.713ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=67 | replacements=0 | latency_p95=538.380ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=67 | replacements=0 | latency_p95=1133.069ms
- Match 15 | seed=120122 | outcome=draw | rounds=120 | replacements=0 | latency_p95=394.048ms
- Match 16 | seed=128041 | outcome=win(P2) | rounds=59 | replacements=0 | latency_p95=604.712ms
- Match 17 | seed=135960 | outcome=win(P2) | rounds=45 | replacements=0 | latency_p95=288.633ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=481.857ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=450.577ms
- Match 20 | seed=159717 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=447.483ms