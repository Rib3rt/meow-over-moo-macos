# AI Strength Self-Play Report

- Generated: 2026-02-19 13:22:58
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `5` (25.00%)
- Player 2 wins: `6` (30.00%)
- Draws: `9` (45.00%)
- Avg rounds: `46.70`
- Decision latency median (ms): `116.369`
- Decision latency p95 (ms): `886.362`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 8
- `no_interaction_limit`: 8
- `opponent_no_units_or_supply`: 3
- `max_round_cap`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=1745 | P1=832 | P2=913
- `attack`: total=1226 | P1=705 | P2=521
- `supply_deploy`: total=510 | P1=257 | P2=253
- `repair`: total=208 | P1=57 | P2=151
- `skip`: total=18 | P1=12 | P2=6

## Unit Usecase Stats

- `Cloudstriker`: total=771 | P1=385 | P2=386 | supply_deploy=80 | move=370 | attack=321
- `Artillery`: total=661 | P1=394 | P2=267 | supply_deploy=79 | move=234 | attack=348
- `Crusher`: total=582 | P1=231 | P2=351 | supply_deploy=97 | move=346 | attack=139
- `Bastion`: total=571 | P1=334 | P2=237 | supply_deploy=74 | move=256 | attack=241
- `Wingstalker`: total=430 | P1=220 | P2=210 | supply_deploy=79 | move=257 | attack=94
- `Healer`: total=353 | P1=124 | P2=229 | supply_deploy=26 | move=104 | attack=15 | repair=208
- `Earthstalker`: total=321 | P1=163 | P2=158 | supply_deploy=75 | move=178 | attack=68
- `SKIP_SLOT`: total=18 | P1=12 | P2=6 | skip=18

## Match Rows

- Match 1 | seed=9256 | outcome=draw | rounds=45 | replacements=0 | latency_p95=1437.784ms
- Match 2 | seed=17175 | outcome=draw | rounds=21 | replacements=0 | latency_p95=171.740ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=61 | replacements=0 | latency_p95=579.706ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=50 | replacements=0 | latency_p95=1044.418ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=59 | replacements=0 | latency_p95=1287.395ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=29 | replacements=0 | latency_p95=1483.833ms
- Match 7 | seed=56770 | outcome=win(P1) | rounds=70 | replacements=0 | latency_p95=2137.815ms
- Match 8 | seed=64689 | outcome=win(P2) | rounds=75 | replacements=0 | latency_p95=1041.133ms
- Match 9 | seed=72608 | outcome=win(P2) | rounds=41 | replacements=0 | latency_p95=912.966ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=67 | replacements=0 | latency_p95=624.331ms
- Match 11 | seed=88446 | outcome=draw | rounds=19 | replacements=0 | latency_p95=223.422ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=47 | replacements=0 | latency_p95=849.330ms
- Match 13 | seed=104284 | outcome=draw | rounds=34 | replacements=0 | latency_p95=786.850ms
- Match 14 | seed=112203 | outcome=draw | rounds=41 | replacements=0 | latency_p95=541.044ms
- Match 15 | seed=120122 | outcome=draw | rounds=20 | replacements=0 | latency_p95=350.652ms
- Match 16 | seed=128041 | outcome=draw | rounds=21 | replacements=0 | latency_p95=173.752ms
- Match 17 | seed=135960 | outcome=draw | rounds=15 | replacements=0 | latency_p95=464.227ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=46 | replacements=0 | latency_p95=755.434ms
- Match 19 | seed=151798 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=564.156ms
- Match 20 | seed=159717 | outcome=draw | rounds=120 | replacements=0 | latency_p95=601.009ms