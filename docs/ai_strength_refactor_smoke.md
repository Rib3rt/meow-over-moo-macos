# AI Strength Self-Play Report

- Generated: 2026-02-20 10:53:13
- Matches: 2
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `base`
- Player 2 reference: `base`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `2` (100.00%)
- Player 2 wins: `0` (0.00%)
- Draws: `0` (0.00%)
- Avg rounds: `52.50`
- Decision latency median (ms): `69.590`
- Decision latency p95 (ms): `640.023`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `opponent_no_units_or_supply`: 2

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=213 | P1=115 | P2=98
- `attack`: total=134 | P1=67 | P2=67
- `supply_deploy`: total=53 | P1=25 | P2=28
- `repair`: total=9 | P1=2 | P2=7
- `skip`: total=6 | P1=0 | P2=6

## Unit Usecase Stats

- `Artillery`: total=87 | P1=31 | P2=56 | supply_deploy=8 | move=36 | attack=43
- `Crusher`: total=82 | P1=43 | P2=39 | supply_deploy=10 | move=52 | attack=20
- `Cloudstriker`: total=64 | P1=36 | P2=28 | supply_deploy=8 | move=33 | attack=23
- `Earthstalker`: total=60 | P1=43 | P2=17 | supply_deploy=8 | move=27 | attack=25
- `Bastion`: total=55 | P1=34 | P2=21 | supply_deploy=8 | move=35 | attack=12
- `Wingstalker`: total=35 | P1=17 | P2=18 | supply_deploy=8 | move=16 | attack=11
- `Healer`: total=26 | P1=5 | P2=21 | supply_deploy=3 | move=14 | repair=9
- `SKIP_SLOT`: total=6 | P1=0 | P2=6 | skip=6

## Match Rows

- Match 1 | seed=9256 | outcome=win(P1) | rounds=44 | replacements=0 | latency_p95=986.032ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=61 | replacements=0 | latency_p95=525.978ms