# AI Strength Self-Play Report

- Generated: 2026-02-20 10:00:53
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `base`
- Player 2 reference: `marge`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `10` (50.00%)
- Player 2 wins: `10` (50.00%)
- Draws: `0` (0.00%)
- Avg rounds: `56.75`
- Decision latency median (ms): `86.182`
- Decision latency p95 (ms): `623.718`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `opponent_no_units_or_supply`: 13
- `commandant_destroyed`: 7

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2368 | P1=1213 | P2=1155
- `attack`: total=1466 | P1=720 | P2=746
- `supply_deploy`: total=551 | P1=277 | P2=274
- `repair`: total=83 | P1=39 | P2=44
- `skip`: total=41 | P1=15 | P2=26

## Unit Usecase Stats

- `Crusher`: total=1003 | P1=508 | P2=495 | supply_deploy=117 | move=594 | attack=292
- `Bastion`: total=769 | P1=342 | P2=427 | supply_deploy=77 | move=401 | attack=291
- `Artillery`: total=740 | P1=355 | P2=385 | supply_deploy=80 | move=357 | attack=303
- `Cloudstriker`: total=648 | P1=344 | P2=304 | supply_deploy=80 | move=334 | attack=234
- `Earthstalker`: total=566 | P1=310 | P2=256 | supply_deploy=80 | move=319 | attack=167
- `Wingstalker`: total=462 | P1=232 | P2=230 | supply_deploy=79 | move=249 | attack=134
- `Healer`: total=280 | P1=158 | P2=122 | supply_deploy=38 | move=114 | attack=45 | repair=83
- `SKIP_SLOT`: total=41 | P1=15 | P2=26 | skip=41

## Match Rows

- Match 1 | seed=9256 | outcome=win(P1) | rounds=59 | replacements=0 | latency_p95=813.683ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=369.444ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=60 | replacements=0 | latency_p95=416.300ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=50 | replacements=0 | latency_p95=605.919ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=1123.401ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=63 | replacements=0 | latency_p95=697.425ms
- Match 7 | seed=56770 | outcome=win(P1) | rounds=48 | replacements=0 | latency_p95=558.338ms
- Match 8 | seed=64689 | outcome=win(P2) | rounds=54 | replacements=0 | latency_p95=981.607ms
- Match 9 | seed=72608 | outcome=win(P1) | rounds=55 | replacements=0 | latency_p95=992.002ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=60 | replacements=0 | latency_p95=691.015ms
- Match 11 | seed=88446 | outcome=win(P2) | rounds=46 | replacements=0 | latency_p95=377.799ms
- Match 12 | seed=96365 | outcome=win(P2) | rounds=55 | replacements=0 | latency_p95=536.923ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=68 | replacements=0 | latency_p95=816.870ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=50 | replacements=0 | latency_p95=281.263ms
- Match 15 | seed=120122 | outcome=win(P1) | rounds=83 | replacements=0 | latency_p95=777.424ms
- Match 16 | seed=128041 | outcome=win(P2) | rounds=66 | replacements=0 | latency_p95=989.022ms
- Match 17 | seed=135960 | outcome=win(P2) | rounds=62 | replacements=0 | latency_p95=442.301ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=43 | replacements=0 | latency_p95=367.728ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=357.434ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=49 | replacements=0 | latency_p95=325.474ms