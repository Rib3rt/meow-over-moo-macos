# AI Strength Self-Play Report

- Generated: 2026-02-20 09:53:21
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `base`
- Player 2 reference: `homer`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `14` (70.00%)
- Player 2 wins: `6` (30.00%)
- Draws: `0` (0.00%)
- Avg rounds: `57.40`
- Decision latency median (ms): `88.118`
- Decision latency p95 (ms): `650.187`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `opponent_no_units_or_supply`: 18
- `commandant_destroyed`: 2

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2405 | P1=1201 | P2=1204
- `attack`: total=1472 | P1=760 | P2=712
- `supply_deploy`: total=545 | P1=272 | P2=273
- `repair`: total=80 | P1=37 | P2=43
- `skip`: total=51 | P1=18 | P2=33

## Unit Usecase Stats

- `Crusher`: total=1027 | P1=471 | P2=556 | supply_deploy=115 | move=618 | attack=294
- `Artillery`: total=855 | P1=422 | P2=433 | supply_deploy=79 | move=387 | attack=389
- `Bastion`: total=770 | P1=412 | P2=358 | supply_deploy=78 | move=455 | attack=237
- `Cloudstriker`: total=665 | P1=364 | P2=301 | supply_deploy=80 | move=342 | attack=243
- `Earthstalker`: total=540 | P1=275 | P2=265 | supply_deploy=80 | move=292 | attack=168
- `Wingstalker`: total=431 | P1=231 | P2=200 | supply_deploy=78 | move=232 | attack=121
- `Healer`: total=214 | P1=95 | P2=119 | supply_deploy=35 | move=79 | attack=20 | repair=80
- `SKIP_SLOT`: total=51 | P1=18 | P2=33 | skip=51

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=531.250ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=522.566ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=506.172ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=51 | replacements=0 | latency_p95=599.736ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=71 | replacements=0 | latency_p95=603.298ms
- Match 6 | seed=48851 | outcome=win(P1) | rounds=57 | replacements=0 | latency_p95=966.153ms
- Match 7 | seed=56770 | outcome=win(P1) | rounds=56 | replacements=0 | latency_p95=519.991ms
- Match 8 | seed=64689 | outcome=win(P2) | rounds=84 | replacements=0 | latency_p95=1374.144ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=743.416ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=40 | replacements=0 | latency_p95=773.911ms
- Match 11 | seed=88446 | outcome=win(P2) | rounds=50 | replacements=0 | latency_p95=566.613ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=50 | replacements=0 | latency_p95=814.862ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=60 | replacements=0 | latency_p95=510.916ms
- Match 14 | seed=112203 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=431.809ms
- Match 15 | seed=120122 | outcome=win(P1) | rounds=56 | replacements=0 | latency_p95=675.680ms
- Match 16 | seed=128041 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=983.427ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=57 | replacements=0 | latency_p95=303.730ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=54 | replacements=0 | latency_p95=486.427ms
- Match 19 | seed=151798 | outcome=win(P1) | rounds=61 | replacements=0 | latency_p95=765.351ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=45 | replacements=0 | latency_p95=318.371ms