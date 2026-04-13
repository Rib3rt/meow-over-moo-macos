# AI Strength Self-Play Report

- Generated: 2026-02-20 11:46:51
- Matches: 2
- Seed: 1337
- Max rounds per match: 120
- Player 1 reference: `base`
- Player 2 reference: `burns`
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `2` (100.00%)
- Player 2 wins: `0` (0.00%)
- Draws: `0` (0.00%)
- Avg rounds: `55.00`
- Decision latency median (ms): `168.296`
- Decision latency p95 (ms): `1195.487`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 2

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=250 | P1=119 | P2=131
- `attack`: total=125 | P1=71 | P2=54
- `supply_deploy`: total=56 | P1=28 | P2=28
- `repair`: total=5 | P1=2 | P2=3

## Unit Usecase Stats

- `Crusher`: total=87 | P1=35 | P2=52 | supply_deploy=12 | move=50 | attack=25
- `Bastion`: total=84 | P1=46 | P2=38 | supply_deploy=8 | move=46 | attack=30
- `Artillery`: total=72 | P1=41 | P2=31 | supply_deploy=8 | move=37 | attack=27
- `Cloudstriker`: total=69 | P1=37 | P2=32 | supply_deploy=8 | move=40 | attack=21
- `Wingstalker`: total=48 | P1=18 | P2=30 | supply_deploy=8 | move=34 | attack=6
- `Earthstalker`: total=47 | P1=34 | P2=13 | supply_deploy=8 | move=23 | attack=16
- `Healer`: total=29 | P1=9 | P2=20 | supply_deploy=4 | move=20 | repair=5

## Match Rows

- Match 1 | seed=9256 | outcome=win(P1) | rounds=62 | replacements=0 | latency_p95=1087.671ms
- Match 2 | seed=17175 | outcome=win(P1) | rounds=48 | replacements=0 | latency_p95=1195.487ms