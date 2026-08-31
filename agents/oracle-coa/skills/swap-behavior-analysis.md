---
name: swap-behavior-analysis
description: "Analyze a wallet’s cumulative behavior inside the pool and over time to detect patterns no point-in-time check can identify. Covers behavioral profile, statistical anomalies vs pool distribution, fraud and exit-liquidity schemes, linked-wallet analysis, and pre-swap DeFi activity. Use whenever wallet history is available, and mandatorily before emitting a score in the block band."
---

# Swap Behavior Analysis: Cumulative Behavioral Analysis

## Role

Functional differentiator of AML (Anti-Money Laundering) Hook.
`wallet-screening` evaluates the address at a point in time. This skill
evaluates cumulative behavior over the wallet history.

Operates on the wallet’s historical window and the pool’s statistical
distribution. Evaluates deviation from expected behavior, not identity.

**Mandatory** before emitting a score in the block band (71–100).

**Demo runtime:** incremental path after `SwapObserved` re-runs this skill with
`uhi10-use-case` then `fact-scoring`. Clean paths may emit mitigants;
hop-contaminated wallets carry NW facts from the A–D memory ledger graph.

---

## Expected inputs

| Field | Description |
|---|---|
| `address` | Address under analysis |
| `swapHistory` | Series of `SwapObserved` events from `afterSwap` |
| `onchainHistory` | Relevant off-pool txs (inbound/outbound, protocol interactions) |
| `poolDistribution` | Pool stats: median/percentiles of amount, frequency, wallet age |
| `analysisWindow` | Period under evaluation |
| `priorScore` | Last oracle `ScoreResult` |

---

## Step 1: Behavioral profile

| Metric | Definition |
|---|---|
| `ageDays` | Days since first recorded tx |
| `totalSwaps` | Swaps executed in the pool |
| `meanAmount` / `medianAmount` | Stats on USD (United States dollar)-converted `amountSpecified` |
| `amountDispersion` | Low dispersion + high frequency → automation / structuring |
| `meanFrequency` | Swaps per unit time |
| `directionalRatio` | Share of `zeroForOne = true` |
| `distinctCounterparties` | Distinct off-pool counterparties |
| `distinctProtocols` | Distinct protocols interacted with |
| `meanRetentionTime` | Time from receipt to subsequent movement |

Compare against own history and pool distribution. Own-history deviation is
more significant than deviation from the pool median (avoids punishing
legitimately atypical profiles).

---

## Step 2: Cumulative typologies

### 2.1 Structuring
N swaps in window T with cumulative sum above threshold, none individually
above. Complement: amounts 80–99% of threshold; regular intervals; low amount
dispersion; directional ratio near 0 or 1.

→ Facts: `STRUCTURING_*` (see `fact-scoring`).

### 2.2 Coordinated smurfing
Same pattern across linked wallets (common funding, co-spend, temporal sync,
homogeneous amounts) → `STRUCTURING_CROSS_WALLET`.

### 2.3 Velocity spike
Period volume > 5× historical mean without pool-activity correlative →
`STRUCTURING_VELOCITY_SPIKE`.

### 2.4 Rapid full-balance transfer
Moves >90% shortly after receipt → `RAPID_FULL_BALANCE_TRANSFER`.

### 2.5 Fraud / exit liquidity / wash patterns
Linked-wallet reciprocal swaps, anomalous LP (liquidity provider) removal,
sandwich adjacency: emit DF facts for `typology-detection` / `fact-scoring`.

---

## Step 3: Alternative hypothesis

Before confirming a cumulative typology, evaluate legitimate economic
explanations (rebalancing, DCA (dollar-cost averaging), arbitrage). Record
evaluation and discard reason. Absence of this analysis weakens the case file.

---

## Step 4: Incremental mode (POST_SWAP)

When intake assigned incremental flow:

1. Incorporate new `SwapObserved`
2. Refresh ST / NW metrics on the updated window
3. Emit only new or materially changed facts
4. Hand off to incremental `fact-scoring`

Do not re-run full sanctions / GEO unless invalidated.

---

## Structured output

```json
{
  "address": "0x...",
  "profile": {
    "ageDays": 0,
    "totalSwaps": 0,
    "meanAmount": 0,
    "directionalRatio": 0
  },
  "anomalies": ["..."],
  "facts": [
    {
      "type": "STRUCTURING_VELOCITY_SPIKE",
      "dimension": "ST",
      "baseWeight": 20,
      "confidence": "LOW | MEDIUM | HIGH",
      "regulatoryBasis": "FATF VA Red Flags Cat. 1",
      "justification": "..."
    }
  ],
  "alternativeHypothesis": {
    "evaluated": true,
    "retained": false,
    "reason": "..."
  },
  "mode": "FULL | INCREMENTAL"
}
```
