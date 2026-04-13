# AI Strength Self-Play Report

- Generated: 2026-02-19 15:09:51
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `5` (25.00%)
- Player 2 wins: `6` (30.00%)
- Draws: `9` (45.00%)
- Avg rounds: `45.65`
- Decision latency median (ms): `107.711`
- Decision latency p95 (ms): `770.427`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 8
- `no_interaction_limit`: 8
- `opponent_no_units_or_supply`: 3
- `max_round_cap`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=1688 | P1=808 | P2=880
- `attack`: total=1194 | P1=685 | P2=509
- `supply_deploy`: total=507 | P1=257 | P2=250
- `repair`: total=215 | P1=57 | P2=158
- `skip`: total=20 | P1=16 | P2=4

## Unit Usecase Stats

- `Cloudstriker`: total=772 | P1=388 | P2=384 | supply_deploy=80 | move=377 | attack=315
- `Artillery`: total=599 | P1=363 | P2=236 | supply_deploy=79 | move=212 | attack=308
- `Crusher`: total=592 | P1=241 | P2=351 | supply_deploy=95 | move=342 | attack=155
- `Bastion`: total=571 | P1=340 | P2=231 | supply_deploy=75 | move=262 | attack=234
- `Wingstalker`: total=417 | P1=205 | P2=212 | supply_deploy=79 | move=246 | attack=92
- `Healer`: total=332 | P1=122 | P2=210 | supply_deploy=24 | move=85 | attack=8 | repair=215
- `Earthstalker`: total=321 | P1=148 | P2=173 | supply_deploy=75 | move=164 | attack=82
- `SKIP_SLOT`: total=20 | P1=16 | P2=4 | skip=20

## Match Rows

- Match 1 | seed=9256 | outcome=draw | rounds=45 | replacements=0 | latency_p95=1313.526ms
- Match 2 | seed=17175 | outcome=draw | rounds=21 | replacements=0 | latency_p95=159.203ms
- Match 3 | seed=25094 | outcome=win(P2) | rounds=54 | replacements=0 | latency_p95=585.011ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=50 | replacements=0 | latency_p95=987.707ms
- Match 5 | seed=40932 | outcome=draw | rounds=22 | replacements=0 | latency_p95=386.527ms
- Match 6 | seed=48851 | outcome=win(P2) | rounds=29 | replacements=0 | latency_p95=1406.926ms
- Match 7 | seed=56770 | outcome=win(P2) | rounds=38 | replacements=0 | latency_p95=1539.959ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=72 | replacements=0 | latency_p95=1020.775ms
- Match 9 | seed=72608 | outcome=draw | rounds=61 | replacements=0 | latency_p95=923.125ms
- Match 10 | seed=80527 | outcome=win(P2) | rounds=67 | replacements=0 | latency_p95=606.045ms
- Match 11 | seed=88446 | outcome=draw | rounds=19 | replacements=0 | latency_p95=216.367ms
- Match 12 | seed=96365 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=545.482ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=60 | replacements=0 | latency_p95=1031.761ms
- Match 14 | seed=112203 | outcome=win(P2) | rounds=47 | replacements=0 | latency_p95=495.230ms
- Match 15 | seed=120122 | outcome=draw | rounds=20 | replacements=0 | latency_p95=342.863ms
- Match 16 | seed=128041 | outcome=draw | rounds=21 | replacements=0 | latency_p95=168.721ms
- Match 17 | seed=135960 | outcome=draw | rounds=15 | replacements=0 | latency_p95=455.453ms
- Match 18 | seed=143879 | outcome=win(P1) | rounds=46 | replacements=0 | latency_p95=739.738ms
- Match 19 | seed=151798 | outcome=win(P1) | rounds=53 | replacements=0 | latency_p95=557.925ms
- Match 20 | seed=159717 | outcome=draw | rounds=120 | replacements=0 | latency_p95=591.525ms