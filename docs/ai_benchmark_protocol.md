# AI Benchmark Protocol

This protocol validates two runtime constraints:
1. Decision latency budget (`<= 500ms` by default)
2. Deterministic sequence selection for identical state

## Runtime Instrumentation (always on)

The AI now records:
- `lastDecisionLatencyMs`
- rolling latency summary (`median`, `p95`)
- determinism checks for identical state keys

Warnings are emitted when:
- single decision exceeds budget
- rolling p95 exceeds budget
- identical state key produces a different action signature

## Manual Determinism + Latency Probe

Use an existing AI instance (`aiPlayer`) and a captured state:

```lua
local state = aiPlayer:getStateFromGrid()
local report = aiPlayer:benchmarkDecisionState(state, 50)
print("runs", report.runs)
print("deterministic", report.deterministic)
print("uniqueSignatures", report.uniqueSignatures)
print("medianMs", report.latency.medianMs)
print("p95Ms", report.latency.p95Ms)
```

Expected:
- `deterministic == true`
- `p95Ms <= 500` (or configured budget)

## Config Knobs

See `ai_config.lua` under `RULE_CONTRACT.PERFORMANCE`:
- `DECISION_BUDGET_MS`
- `MAX_SAMPLE_WINDOW`
- `REPORT_INTERVAL`
- `DETERMINISM_CHECK`
- `DETERMINISM_CACHE_SIZE`
