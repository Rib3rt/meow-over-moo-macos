# AI Strength Self-Play Report

- Generated: 2026-02-12 14:13:06
- Matches: 50
- Seed: 1337
- Max rounds per match: 120
- Decision budget target (ms): 500

## Summary

- Player 1 wins: `18` (36.00%)
- Player 2 wins: `18` (36.00%)
- Draws: `14` (28.00%)
- Avg rounds: `29.54`
- Decision latency median (ms): `15.018`
- Decision latency p95 (ms): `79.231`
- Action replacements (invalid/skip sanitized): `0`

## Outcome Reasons

- `commandant_destroyed`: 33
- `no_interaction_limit`: 14
- `opponent_no_units_or_supply`: 3

## Replacement Reasons

- none

## Action Type Usage

- `move`: total=3578 | P1=1821 | P2=1757
- `attack`: total=1479 | P1=734 | P2=745
- `supply_deploy`: total=666 | P1=340 | P2=326
- `repair`: total=86 | P1=33 | P2=53
- `skip`: total=19 | P1=12 | P2=7

## Unit Usecase Stats

- `Cloudstriker`: total=2494 | P1=1188 | P2=1306 | supply_deploy=185 | move=1671 | attack=638
- `Artillery`: total=1072 | P1=580 | P2=492 | supply_deploy=136 | move=573 | attack=363
- `Crusher`: total=597 | P1=305 | P2=292 | supply_deploy=91 | move=363 | attack=143
- `Wingstalker`: total=542 | P1=275 | P2=267 | supply_deploy=100 | move=354 | attack=88
- `Healer`: total=489 | P1=229 | P2=260 | supply_deploy=60 | move=274 | attack=69 | repair=86
- `Earthstalker`: total=397 | P1=224 | P2=173 | supply_deploy=67 | move=218 | attack=112
- `Bastion`: total=218 | P1=127 | P2=91 | supply_deploy=27 | move=125 | attack=66
- `SKIP_SLOT`: total=19 | P1=12 | P2=7 | skip=19

## Match Rows

- Match 1 | seed=9256 | outcome=win(P2) | rounds=8 | replacements=0 | latency_p95=104.307ms
- Match 2 | seed=17175 | outcome=draw | rounds=32 | replacements=0 | latency_p95=57.300ms
- Match 3 | seed=25094 | outcome=win(P1) | rounds=13 | replacements=0 | latency_p95=36.598ms
- Match 4 | seed=33013 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=29.038ms
- Match 5 | seed=40932 | outcome=win(P2) | rounds=41 | replacements=0 | latency_p95=68.202ms
- Match 6 | seed=48851 | outcome=draw | rounds=46 | replacements=0 | latency_p95=69.271ms
- Match 7 | seed=56770 | outcome=draw | rounds=43 | replacements=0 | latency_p95=62.243ms
- Match 8 | seed=64689 | outcome=win(P1) | rounds=14 | replacements=0 | latency_p95=35.030ms
- Match 9 | seed=72608 | outcome=draw | rounds=28 | replacements=0 | latency_p95=99.341ms
- Match 10 | seed=80527 | outcome=draw | rounds=44 | replacements=0 | latency_p95=70.025ms
- Match 11 | seed=88446 | outcome=win(P1) | rounds=38 | replacements=0 | latency_p95=60.524ms
- Match 12 | seed=96365 | outcome=win(P1) | rounds=44 | replacements=0 | latency_p95=89.712ms
- Match 13 | seed=104284 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=104.765ms
- Match 14 | seed=112203 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=77.401ms
- Match 15 | seed=120122 | outcome=draw | rounds=37 | replacements=0 | latency_p95=82.587ms
- Match 16 | seed=128041 | outcome=draw | rounds=37 | replacements=0 | latency_p95=70.009ms
- Match 17 | seed=135960 | outcome=win(P1) | rounds=18 | replacements=0 | latency_p95=62.020ms
- Match 18 | seed=143879 | outcome=win(P2) | rounds=37 | replacements=0 | latency_p95=68.811ms
- Match 19 | seed=151798 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=76.709ms
- Match 20 | seed=159717 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=70.064ms
- Match 21 | seed=167636 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=41.914ms
- Match 22 | seed=175555 | outcome=win(P1) | rounds=35 | replacements=0 | latency_p95=87.299ms
- Match 23 | seed=183474 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=27.635ms
- Match 24 | seed=191393 | outcome=draw | rounds=41 | replacements=0 | latency_p95=50.976ms
- Match 25 | seed=199312 | outcome=win(P1) | rounds=17 | replacements=0 | latency_p95=101.160ms
- Match 26 | seed=207231 | outcome=draw | rounds=32 | replacements=0 | latency_p95=85.146ms
- Match 27 | seed=215150 | outcome=win(P2) | rounds=39 | replacements=0 | latency_p95=48.324ms
- Match 28 | seed=223069 | outcome=win(P2) | rounds=75 | replacements=0 | latency_p95=112.745ms
- Match 29 | seed=230988 | outcome=win(P1) | rounds=7 | replacements=0 | latency_p95=61.629ms
- Match 30 | seed=238907 | outcome=win(P2) | rounds=12 | replacements=0 | latency_p95=57.155ms
- Match 31 | seed=246826 | outcome=win(P1) | rounds=6 | replacements=0 | latency_p95=38.403ms
- Match 32 | seed=254745 | outcome=win(P2) | rounds=33 | replacements=0 | latency_p95=104.927ms
- Match 33 | seed=262664 | outcome=draw | rounds=23 | replacements=0 | latency_p95=74.629ms
- Match 34 | seed=270583 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=47.084ms
- Match 35 | seed=278502 | outcome=draw | rounds=36 | replacements=0 | latency_p95=100.763ms
- Match 36 | seed=286421 | outcome=win(P2) | rounds=69 | replacements=0 | latency_p95=92.080ms
- Match 37 | seed=294340 | outcome=win(P1) | rounds=25 | replacements=0 | latency_p95=75.519ms
- Match 38 | seed=302259 | outcome=win(P1) | rounds=9 | replacements=0 | latency_p95=91.411ms
- Match 39 | seed=310178 | outcome=win(P1) | rounds=24 | replacements=0 | latency_p95=82.942ms
- Match 40 | seed=318097 | outcome=win(P2) | rounds=9 | replacements=0 | latency_p95=51.966ms
- Match 41 | seed=326016 | outcome=draw | rounds=34 | replacements=0 | latency_p95=55.839ms
- Match 42 | seed=333935 | outcome=win(P1) | rounds=15 | replacements=0 | latency_p95=72.282ms
- Match 43 | seed=341854 | outcome=win(P2) | rounds=53 | replacements=0 | latency_p95=64.756ms
- Match 44 | seed=349773 | outcome=draw | rounds=29 | replacements=0 | latency_p95=92.213ms
- Match 45 | seed=357692 | outcome=draw | rounds=92 | replacements=0 | latency_p95=92.418ms
- Match 46 | seed=365611 | outcome=win(P1) | rounds=83 | replacements=0 | latency_p95=85.717ms
- Match 47 | seed=373530 | outcome=win(P1) | rounds=12 | replacements=0 | latency_p95=100.817ms
- Match 48 | seed=381449 | outcome=win(P2) | rounds=18 | replacements=0 | latency_p95=58.971ms
- Match 49 | seed=389368 | outcome=win(P2) | rounds=16 | replacements=0 | latency_p95=62.330ms
- Match 50 | seed=397287 | outcome=win(P2) | rounds=10 | replacements=0 | latency_p95=25.329ms