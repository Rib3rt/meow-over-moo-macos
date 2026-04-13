# AI Strength Self-Play Report

- Generated: 2026-02-19 11:07:07
- Matches: 5
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `1` (20.00%)
- Player 2 wins: `0` (0.00%)
- Draws: `4` (80.00%)
- Avg rounds: `42.00`
- Decision latency median (ms): `480.570`
- Decision latency p95 (ms): `1315.859`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `no_interaction_limit`: 4
- `commandant_destroyed`: 1

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=477 | P1=232 | P2=245
- `attack`: total=157 | P1=99 | P2=58
- `supply_deploy`: total=135 | P1=68 | P2=67
- `repair`: total=60 | P1=21 | P2=39
- `skip`: total=5 | P1=0 | P2=5

## Unit Usecase Stats

- `Cloudstriker`: total=202 | P1=128 | P2=74 | supply_deploy=20 | move=125 | attack=57
- `Artillery`: total=125 | P1=57 | P2=68 | supply_deploy=20 | move=70 | attack=35
- `Bastion`: total=125 | P1=50 | P2=75 | supply_deploy=20 | move=90 | attack=15
- `Earthstalker`: total=114 | P1=66 | P2=48 | supply_deploy=20 | move=81 | attack=13
- `Wingstalker`: total=91 | P1=38 | P2=53 | supply_deploy=20 | move=48 | attack=23
- `Crusher`: total=87 | P1=44 | P2=43 | supply_deploy=26 | move=48 | attack=13
- `Healer`: total=85 | P1=37 | P2=48 | supply_deploy=9 | move=15 | attack=1 | repair=60
- `SKIP_SLOT`: total=5 | P1=0 | P2=5 | skip=5

## Match Rows

- Match 1 | seed=9256 | outcome=draw | rounds=14 | replacements=0 | latency_p95=959.480ms
- Match 2 | seed=17175 | outcome=draw | rounds=49 | replacements=0 | latency_p95=1506.286ms
- Match 3 | seed=25094 | outcome=draw | rounds=74 | replacements=0 | latency_p95=626.064ms
- Match 4 | seed=33013 | outcome=draw | rounds=24 | replacements=0 | latency_p95=1224.421ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=49 | replacements=0 | latency_p95=1519.889ms