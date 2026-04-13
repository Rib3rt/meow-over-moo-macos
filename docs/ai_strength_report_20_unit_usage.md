# AI Strength Self-Play Report

- Generated: 2026-02-12 13:24:52
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `10` (50.00%)
- Player 2 wins: `6` (30.00%)
- Draws: `4` (20.00%)
- Avg rounds: `44.70`
- Decision latency median (ms): `12.099`
- Decision latency p95 (ms): `41.412`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 13
- `no_interaction_limit`: 4
- `opponent_no_units_or_supply`: 3

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2115 | P1=1086 | P2=1029
- `attack`: total=945 | P1=467 | P2=478
- `supply_deploy`: total=413 | P1=200 | P2=213
- `repair`: total=61 | P1=29 | P2=32
- `skip`: total=10 | P1=0 | P2=10

## Unit Usecase Stats

- `Cloudstriker`: total=1063 | P1=585 | P2=478 | supply_deploy=78 | move=698 | attack=287
- `Crusher`: total=578 | P1=291 | P2=287 | supply_deploy=79 | move=353 | attack=146
- `Artillery`: total=512 | P1=265 | P2=247 | supply_deploy=72 | move=243 | attack=197
- `Wingstalker`: total=412 | P1=193 | P2=219 | supply_deploy=58 | move=271 | attack=83
- `Bastion`: total=354 | P1=159 | P2=195 | supply_deploy=39 | move=196 | attack=119
- `Earthstalker`: total=339 | P1=144 | P2=195 | supply_deploy=57 | move=199 | attack=83
- `Healer`: total=276 | P1=145 | P2=131 | supply_deploy=30 | move=155 | attack=30 | repair=61
- `SKIP_SLOT`: total=10 | P1=0 | P2=10 | skip=10

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=60 | replacements=0 | latency_p95=50.813ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=23 | replacements=0 | latency_p95=24.328ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=69 | replacements=0 | latency_p95=23.858ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=72 | replacements=0 | latency_p95=38.313ms
- Match 5 | seed=40932 | outcome=draw | rounds=50 | replacements=0 | latency_p95=38.890ms
- Match 6 | seed=48851 | outcome=draw | rounds=40 | replacements=0 | latency_p95=28.852ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=15 | replacements=0 | latency_p95=30.985ms
- Match 8 | seed=64689 | outcome=win(P2) | rounds=28 | replacements=0 | latency_p95=28.545ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=22 | replacements=0 | latency_p95=43.641ms
- Match 10 | seed=80527 | outcome=draw | rounds=43 | replacements=0 | latency_p95=55.883ms
- Match 11 | seed=88446 | outcome=win(P2) | rounds=64 | replacements=0 | latency_p95=30.558ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=65 | replacements=0 | latency_p95=47.860ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=76 | replacements=0 | latency_p95=56.009ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=25.712ms
- Match 15 | seed=120122 | outcome=win(P1) | rounds=16 | replacements=0 | latency_p95=23.970ms
- Match 16 | seed=128041 | outcome=win(P2) | rounds=75 | replacements=0 | latency_p95=49.389ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=8 | replacements=0 | latency_p95=37.439ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=78 | replacements=0 | latency_p95=26.607ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=38 | replacements=0 | latency_p95=29.945ms
- Match 20 | seed=159717 | outcome=draw | rounds=39 | replacements=0 | latency_p95=16.367ms