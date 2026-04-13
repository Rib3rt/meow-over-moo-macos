# AI Strength Self-Play Report

- Generated: 2026-02-20 09:45:19
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `base`
- Player 2 reference: `maggie`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `8` (40.00%)
- Player 2 wins: `12` (60.00%)
- Draws: `0` (0.00%)
- Avg rounds: `53.65`
- Decision latency median (ms): `72.494`
- Decision latency p95 (ms): `532.818`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `opponent_no_units_or_supply`: 12
- `commandant_destroyed`: 8

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2191 | P1=1108 | P2=1083
- `attack`: total=1400 | P1=702 | P2=698
- `supply_deploy`: total=532 | P1=265 | P2=267
- `repair`: total=74 | P1=42 | P2=32
- `skip`: total=65 | P1=25 | P2=40

## Unit Usecase Stats

- `Crusher`: total=830 | P1=415 | P2=415 | supply_deploy=113 | move=457 | attack=260
- `Bastion`: total=746 | P1=356 | P2=390 | supply_deploy=77 | move=379 | attack=290
- `Artillery`: total=706 | P1=345 | P2=361 | supply_deploy=78 | move=340 | attack=288
- `Cloudstriker`: total=675 | P1=354 | P2=321 | supply_deploy=80 | move=331 | attack=264
- `Earthstalker`: total=515 | P1=288 | P2=227 | supply_deploy=73 | move=293 | attack=149
- `Wingstalker`: total=480 | P1=242 | P2=238 | supply_deploy=77 | move=269 | attack=134
- `Healer`: total=245 | P1=117 | P2=128 | supply_deploy=34 | move=122 | attack=15 | repair=74
- `SKIP_SLOT`: total=65 | P1=25 | P2=40 | skip=65

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=37 | replacements=0 | latency_p95=1150.318ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=41 | replacements=0 | latency_p95=642.977ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=50 | replacements=0 | latency_p95=413.708ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=61 | replacements=0 | latency_p95=303.968ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=52 | replacements=0 | latency_p95=706.700ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=459.741ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=51 | replacements=0 | latency_p95=423.555ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=50 | replacements=0 | latency_p95=387.017ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=66 | replacements=0 | latency_p95=531.351ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=49 | replacements=0 | latency_p95=475.559ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=54 | replacements=0 | latency_p95=508.915ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=751.096ms
- Match 13 | seed=104284 | outcome=win(P2) | rounds=78 | replacements=0 | latency_p95=731.606ms
- Match 14 | seed=112203 | outcome=win(P2) | rounds=61 | replacements=0 | latency_p95=463.161ms
- Match 15 | seed=120122 | outcome=win(P2) | rounds=76 | replacements=0 | latency_p95=677.350ms
- Match 16 | seed=128041 | outcome=win(P2) | rounds=68 | replacements=0 | latency_p95=648.875ms
- Match 17 | seed=135960 | outcome=win(P2) | rounds=65 | replacements=0 | latency_p95=365.663ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=60 | replacements=0 | latency_p95=737.915ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=47 | replacements=0 | latency_p95=356.442ms
- Match 20 | seed=159717 | outcome=win(P2) | rounds=44 | replacements=0 | latency_p95=616.653ms