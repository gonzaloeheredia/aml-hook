---
name: model-validation
description: "Validate and document scoring-system performance: threshold justification under the risk-based approach, backtesting against known cases, false positive/negative measurement, parameter sensitivity, model drift detection, and independent testing. Use periodically, on every governable-parameter change, and before answering client-protocol due diligence or a supervisor request."
---

# Model Validation — Scoring System Validation

## Role

A supervisor examines the system before individual cases. The prior question:
how do we know the thresholds work?

This skill produces the evidence that answers that. Without it the pack emits
scores without accredited calibration — a weakness against BSA independent-
testing expectations and FATF’s requirement that controls be proportionate and
founded.

Also the material used to answer due diligence from a protocol evaluating hook
integration.

---

## Expected inputs

| Field | Description |
|---|---|
| `period` | Validation window |
| `poolIds` | Included pools |
| `emittedScores` | Period `ScoreResult` series with breakdown |
| `executedDecisions` | `task-swap-decision` outputs |
| `labeledCases` | Wallets with known ex-post classification |
| `activeParameters` | Effective governable parameter values |
| `parameterHistory` | Changes executed and their basis |
| `resolvedDisputes` | Period `dispute-remediation` output |

---

## Step 1: Threshold justification

Every governable parameter needs documented basis. An unjustified threshold is
arbitrary; an arbitrary control fails the RBA.

For each parameter document: current value, normative basis, empirical pool
basis, alternatives considered, last review date, decision owner.

Example: report threshold is not justified as “usual”; justify with the
orienting framework, observed amount distribution, share above/below, and
measured detection-rate effect when moved.

**Immutable (not recalibrated here):** score→`hookOutput` mapping
(`ALLOW` / `FEE_OVERRIDE` / `REVERT`), sanctions override, HIGH-fact rule for
block, mitigant cap, external-signal ceiling.

---

## Step 2: Labeled case set

| Source | Label type |
|---|---|
| Designated addresses with designation date | Confirmed positive, known time |
| Addresses tied to documented exploits | Confirmed positive |
| Wallets in public investigations | Confirmed positive |
| Disputes resolved for the participant | Confirmed negative |
| Operator-verified institutional wallets | Confirmed negative |
| Synthetic cases | Positive/negative with synthetic warning |

**Temporal honesty.** Backtest with information available at the time of the
fact, not later. A March designation is not a hit if the model only saw the
April list. Reconstruct source state at evaluation date and declare it.

---

## Step 3: Performance metrics

| Metric | Definition | Relevance |
|---|---|---|
| True-positive rate | Confirmed positives in BLOCK or ELEVATED | Detection capacity |
| False-positive rate | Confirmed negatives in BLOCK | Cost on legitimate users; dispute source |
| False-negative rate | Confirmed positives in STANDARD | Operator exposure |
| Early detection | Positives elevated before designation/incident | Differentiator vs list systems |
| Mean lead time | Time from score elevation to external confirmation | Size of differentiator |
| Score distribution | Histogram by band | Detect anomalous concentration |
| FEE_OVERRIDE conversion | Mid-band cases that later become BLOCK or clear | Mid-band calibration quality |

Asymmetry: false negatives expose the operator; false positives create
disputes. Do not optimize only one side.

---

## Step 4: Sensitivity and drift

Perturb governable parameters within plausible ranges; measure metric movement.
Flag drift when period metrics diverge materially from baseline without
explained population change.

After any Timelock parameter change, run a focused validation before treating
the new calibration as production-stable.

---

## Step 5: Independent testing pack

Produce a package for third-party / audit review: threshold justifications,
backtest methodology and temporal reconstruction, metrics, sensitivity,
drift, dispute outcomes, known limitations (including mock vs live gaps).

Never publish effective secret threshold values in public materials; ranges of
`hookOutput` bands are public.

---

## Structured output

```json
{
  "period": {"from": "...", "to": "..."},
  "metrics": {
    "truePositiveRate": null,
    "falsePositiveRate": null,
    "falseNegativeRate": null,
    "earlyDetectionRate": null
  },
  "thresholdJustifications": [],
  "driftFlags": [],
  "sensitivityFindings": [],
  "limitations": [
    "Demo mock uses deterministic N-hop ledger facts without live vendor APIs"
  ],
  "auditHash": "...",
  "recommendation": "retain | recalibrate | escalate"
}
```
