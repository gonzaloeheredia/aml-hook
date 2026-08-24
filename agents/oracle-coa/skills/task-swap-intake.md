---
name: task-swap-intake
description: "Receive and classify a swap event or wallet evaluation request before assigning the analysis flow. Determines evaluation mode, extracts swap parameters, checks oracle score validity, and defines which domain skills must run. Always use as the first step on a new event: inbound swap, afterSwap update, LP report, or scheduled wallet review."
---

# Task: Swap Intake — Event Reception and Classification

## Role

Entry point of the agent. Structures the received event, determines evaluation
mode, and defines the workflow. Does not analyze substance: classifies and routes.

---

## Evaluation modes

| Mode | Trigger | Latency | Depth |
|---|---|---|---|
| **PRECOMPUTE** | New wallet or scheduled expiry review | High — async | Full |
| **POST_SWAP** | `SwapObserved` from `afterSwap` | Medium — seconds to minutes | Incremental on ST / NW |
| **ON_DEMAND** | Explicit operator / Compliance Officer request | High | Full, with case file |
| **ALERT** | Validated LP report, Forta alert, sanctions list update | Immediate | Directed at triggering fact |
| **DISPUTE** | Admitted challenge, external signal retraction, forwarder key revocation | High | Recalc on challenged facts |
| **DEFERRED_ATTRIBUTION** | Previously blocked for failed attribution, queued for trace resolution | High | Attribution then full eval if resolved |

**Latency rule.** No mode runs inside `beforeSwap`. The hook reads the
precomputed oracle score. If no valid score exists, the hook applies the
operator default policy and intake records `PRECOMPUTE` at high priority.

Demo triggers (`apps/api/src/oracle/agent.ts`): `seed` · `transfer` ·
`afterSwap` · `blocked` · `manual`.

---

## Step 1: Field extraction

| Field | Description |
|---|---|
| `eventId` | Event identifier |
| `mode` | PRECOMPUTE / POST_SWAP / ON_DEMAND / ALERT / … |
| `origin` | Hook / off-chain engine / operator / LP report / external |
| `evaluatedAddress` | Address under analysis |
| `role` | SENDER or RECIPIENT |
| `poolId` | Uniswap v4 pool |
| `amountSpecified` | Swap amount (signed) |
| `zeroForOne` | Swap direction |
| `currencyIn` / `currencyOut` | Pair tokens |
| `blockNumber` / `blockTimestamp` | Event time |
| `txHash` | Transaction, if any |
| `currentScore` | Oracle score and calculation time |
| `missingInformation` | What is needed and unavailable |

`amountSpecified` feeds structuring detection. `zeroForOne` feeds directional
series analysis (unilateral extraction vs bidirectional trading).

---

## Step 2: Score validity check

| State | Criterion | Action |
|---|---|---|
| **Valid** | Within review period for its band | POST_SWAP → incremental; others → no recalc |
| **Expired** | Past review period | Full recalc |
| **Missing** | No registered score | Full recalc, high priority |
| **Invalidated** | Sanctions list change or affecting alert | Immediate recalc |

---

## Step 3: Urgency classification

| Level | Criterion | Response |
|---|---|---|
| **Critical** | Sanctions hit, designated contract, TF nexus, active exploit alert | Immediate → `task-blocking-protocol` |
| **High** | Prior score ≥ 71, active cumulative typology, validated LP report, unscored wallet assessed USD ≥ $1,000 (hook 8% or $15,000 REVERT) | Priority recalc |
| **Medium** | Prior 31–70, routine post-swap, new wallet assessed USD < $1,000 (hook 3% band) | Standard queue |
| **Low** | Scheduled review in STANDARD band | Deferred queue |

---

## Step 4: Flow assignment

```
Always first                 → originator-attribution
Attribution resolved         → ofac-screening
Every evaluation             → wallet-screening
History available            → swap-behavior-analysis
Patterns detected            → typology-detection
Signals from other pools     → cross-pool-intelligence
Every evaluation             → fact-scoring
Every evaluation             → task-swap-decision
Critical urgency             → task-blocking-protocol (parallel)
Reasonable suspicion         → task-regulatory-report
Challenge received           → dispute-remediation
New pool setup               → protocol-obligations
Periodic validation          → model-validation
```

**Two-level precedence.** `originator-attribution` first. Without an attributed
subject, analysis is impossible; under default restrictive policy the swap
reverts with `ATTRIBUTION_FAILED` and no other skill runs.

After attribution, `ofac-screening` before any other domain skill. A direct
match stops the flow and routes to `task-blocking-protocol`.

**Conditional skip.** In `POST_SWAP` with a valid score and no new S/MX/GEO
facts, reduce to `swap-behavior-analysis` + incremental `fact-scoring`
(+ decision + report in the mock).

Mock flows:

- **FULL:** intake → attribution → ofac → evidence → wallet → behavior →
  typology → cross-pool → fact-scoring → decision → report
- **INCREMENTAL:** intake → behavior → fact-scoring → decision → report

---

## Structured output

```json
{
  "eventId": "...",
  "mode": "PRECOMPUTE | POST_SWAP | ON_DEMAND | ALERT | DISPUTE | DEFERRED_ATTRIBUTION",
  "origin": "...",
  "evaluatedAddress": "0x...",
  "role": "SENDER | RECIPIENT",
  "swap": {
    "poolId": "0x...",
    "amountSpecified": "0",
    "zeroForOne": true,
    "currencyIn": "0x...",
    "currencyOut": "0x...",
    "blockNumber": 0,
    "txHash": "0x..."
  },
  "oracleScore": {
    "exists": true,
    "finalScore": 0,
    "calculatedAt": "<ISO 8601>",
    "state": "valid | expired | missing | invalidated"
  },
  "urgency": "critical | high | medium | low",
  "attribution": {
    "resolved": true,
    "addressToEvaluate": "0x...",
    "method": "...",
    "policyApplied": "restrictive"
  },
  "assignedFlow": ["originator-attribution", "ofac-screening", "..."],
  "missingInformation": ["..."],
  "intakeNotes": "..."
}
```

> Operates on information available at event receipt. If insufficient to
> classify, record the gap and assign the full flow by default — missing data
> must not be resolved by assuming low risk.
