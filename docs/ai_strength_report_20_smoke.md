# AI Strength Self-Play Report

- Generated: 2026-02-19 09:21:08
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `11` (55.00%)
- Player 2 wins: `8` (40.00%)
- Draws: `1` (5.00%)
- Avg rounds: `59.20`
- Decision latency median (ms): `32.425`
- Decision latency p95 (ms): `157.884`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 11
- `opponent_no_units_or_supply`: 8
- `no_interaction_limit`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2428 | P1=1221 | P2=1207
- `attack`: total=1557 | P1=773 | P2=784
- `supply_deploy`: total=520 | P1=258 | P2=262
- `skip`: total=127 | P1=74 | P2=53
- `repair`: total=70 | P1=32 | P2=38

## Unit Usecase Stats

- `Cloudstriker`: total=912 | P1=466 | P2=446 | supply_deploy=78 | move=516 | attack=318
- `Crusher`: total=854 | P1=417 | P2=437 | supply_deploy=109 | move=467 | attack=278
- `Artillery`: total=821 | P1=357 | P2=464 | supply_deploy=80 | move=393 | attack=348
- `Bastion`: total=599 | P1=308 | P2=291 | supply_deploy=67 | move=282 | attack=250
- `Earthstalker`: total=580 | P1=358 | P2=222 | supply_deploy=74 | move=344 | attack=162
- `Wingstalker`: total=501 | P1=219 | P2=282 | supply_deploy=76 | move=285 | attack=140
- `Healer`: total=308 | P1=159 | P2=149 | supply_deploy=36 | move=141 | attack=61 | repair=70
- `SKIP_SLOT`: total=127 | P1=74 | P2=53 | skip=127

## Match Rows

- Match 1 | seed=9256 | outcome=win(P1) | rounds=57 | replacements=0 | latency_p95=135.343ms
- Match 2 | seed=17175 | outcome=win(P2) | rounds=60 | replacements=0 | latency_p95=127.850ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=245.034ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=65 | replacements=0 | latency_p95=152.060ms
- Match 5 | seed=40932 | outcome=draw | rounds=64 | replacements=0 | latency_p95=264.505ms
- Match 6 | seed=48851 | outcome=win(P1) | rounds=64 | replacements=0 | latency_p95=142.981ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=65 | replacements=0 | latency_p95=189.043ms
- Match 8 | seed=64689 | outcome=win(P2) | rounds=68 | replacements=0 | latency_p95=117.707ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=69 | replacements=0 | latency_p95=203.070ms
- Match 10 | seed=80527 | outcome=win(P1) | rounds=56 | replacements=0 | latency_p95=157.497ms
- Match 11 | seed=88446 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=157.789ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=50 | replacements=0 | latency_p95=165.115ms
- Match 13 | seed=104284 | outcome=win(P2) | rounds=71 | replacements=0 | latency_p95=130.930ms
- Match 14 | seed=112203 | outcome=win(P2) | rounds=33 | replacements=0 | latency_p95=116.578ms
- Match 15 | seed=120122 | outcome=win(P1) | rounds=72 | replacements=0 | latency_p95=127.729ms
- Match 16 | seed=128041 | outcome=win(P2) | rounds=48 | replacements=0 | latency_p95=160.035ms
- Match 17 | seed=135960 | outcome=win(P2) | rounds=63 | replacements=0 | latency_p95=156.623ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=78 | replacements=0 | latency_p95=159.753ms
- Match 19 | seed=151798 | outcome=win(P1) | rounds=66 | replacements=0 | latency_p95=171.933ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=55 | replacements=0 | latency_p95=154.701ms