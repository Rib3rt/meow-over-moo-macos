# AI Strength Self-Play Report

- Generated: 2026-02-12 17:17:20
- Matches: 20
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `12` (60.00%)
- Player 2 wins: `2` (10.00%)
- Draws: `6` (30.00%)
- Avg rounds: `46.05`
- Decision latency median (ms): `24.050`
- Decision latency p95 (ms): `106.777`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 14
- `no_interaction_limit`: 6

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=2184 | P1=1070 | P2=1114
- `attack`: total=958 | P1=529 | P2=429
- `supply_deploy`: total=399 | P1=197 | P2=202
- `repair`: total=88 | P1=27 | P2=61
- `skip`: total=16 | P1=10 | P2=6

## Unit Usecase Stats

- `Cloudstriker`: total=1228 | P1=626 | P2=602 | supply_deploy=79 | move=765 | attack=384
- `Artillery`: total=516 | P1=293 | P2=223 | supply_deploy=75 | move=244 | attack=197
- `Wingstalker`: total=513 | P1=224 | P2=289 | supply_deploy=61 | move=361 | attack=91
- `Crusher`: total=478 | P1=247 | P2=231 | supply_deploy=68 | move=288 | attack=122
- `Earthstalker`: total=339 | P1=185 | P2=154 | supply_deploy=51 | move=231 | attack=57
- `Healer`: total=325 | P1=144 | P2=181 | supply_deploy=35 | move=159 | attack=43 | repair=88
- `Bastion`: total=230 | P1=104 | P2=126 | supply_deploy=30 | move=136 | attack=64
- `SKIP_SLOT`: total=16 | P1=10 | P2=6 | skip=16

## Match Rows

- Match 1 | seed=9256 | outcome=draw | rounds=41 | replacements=0 | latency_p95=87.447ms
- Match 2 | seed=17175 | outcome=draw | rounds=24 | replacements=0 | latency_p95=88.611ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=23 | replacements=0 | latency_p95=45.674ms
- Match 4 | seed=33013 | outcome=win(P1) | rounds=27 | replacements=0 | latency_p95=78.157ms
- Match 5 | seed=40932 | outcome=win(P1) | rounds=42 | replacements=0 | latency_p95=83.715ms
- Match 6 | seed=48851 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=70.676ms
- Match 7 | seed=56770 | outcome=win(P1) | rounds=59 | replacements=0 | latency_p95=92.082ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=39 | replacements=0 | latency_p95=70.213ms
- Match 9 | seed=72608 | outcome=draw | rounds=91 | replacements=0 | latency_p95=110.900ms
- Match 10 | seed=80527 | outcome=win(P1) | rounds=35 | replacements=0 | latency_p95=87.529ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=174.807ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=63 | replacements=0 | latency_p95=209.034ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=32 | replacements=0 | latency_p95=112.941ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=77.957ms
- Match 15 | seed=120122 | outcome=win(P2) | rounds=56 | replacements=0 | latency_p95=93.133ms
- Match 16 | seed=128041 | outcome=draw | rounds=63 | replacements=0 | latency_p95=77.843ms
- Match 17 | seed=135960 | outcome=draw | rounds=87 | replacements=0 | latency_p95=121.140ms
- Match 18 | seed=143879 | outcome=draw | rounds=47 | replacements=0 | latency_p95=58.633ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=77 | replacements=0 | latency_p95=126.728ms
- Match 20 | seed=159717 | outcome=win(P1) | rounds=67 | replacements=0 | latency_p95=113.584ms