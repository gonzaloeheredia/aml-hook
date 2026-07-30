---
name: task-swap-decision
description: "Translate the fact-scoring score into the ternary output AML Hook executes: allow with standard fee, apply FEE_OVERRIDE, or REVERT. Verifies override rules, validates evidentiary sufficiency, defines FEE_OVERRIDE escrow destination, and produces the on-chain reason basis. Use after fact-scoring, before task-regulatory-report."
---

# Task: Swap Decision — Hook Output Determination

## Role

Takes `ScoreResult` and produces the decision the hook executes. Synthesis
point where analysis becomes an economic action on a real operation.

The decision is ternary — the operational translation of FATF Rec. 1 (RBA).
A binary system treats mid-risk like low risk, or mid-risk like high risk;
neither satisfies Rec. 1.

---

## Expected inputs

| Field | Description |
|---|---|
| `scoreResult` | Full `fact-scoring` output |
| `ofacOutput` | `ofac-screening` output |
| `typologyOutput` | Typologies and FATF category multiplicity |
| `poolConfig` | Mode, governable thresholds, fee multiplier, default policy |
| `caseFile` | `task-onchain-evidence` output, including gaps / degraded mode |

---

## Step 1: Override checks

Overrides admit no weighting.

| Rule | Condition | Effect |
|---|---|---|
| Direct sanctions match | `OFAC_DIRECT_MATCH`, `UN_DIRECT_MATCH`, `EU_DIRECT_MATCH` | Score 100. `hookOutput: REVERT`. Activate `task-blocking-protocol` |
| Designated contract | `SANCTIONED_CONTRACT_DIRECT` | Same |
| TF / proliferation nexus | `TERRORISM_FINANCING` | Same, max urgency |
| Designated Smart Account controller | Hit on any controller | Preventive `REVERT` + mandatory human review |
| Level-1 evidence unavailable | `level1Available: false` | Suspend evaluation; apply pool default policy |
| Originator attribution unresolved | `attribution.resolved: false` under restrictive policy | `REVERT` with `ATTRIBUTION_FAILED`. No profile built. Queue deferred resolution if enabled |

---

## Step 2: Score → hook output mapping

| Range | hookOutput | Hook effect |
|---|---|---|
| 0–30 | `ALLOW` | Swap at standard fee. Verification event emitted |
| 31–70 | `FEE_OVERRIDE` | Swap with configured multiplier / `lpFeeOverride`. Monitoring event with basis |
| 71–99 | `REVERT` | Swap reverted. Reason recorded on-chain |
| 100 | `REVERT` + block | Revert + blocking protocol |

**Mid-band rationale.** Band 31–70 = atypical behavior without confirmed
designation. No legal duty to hard-block. The regulatory standard is enhanced
monitoring — `FEE_OVERRIDE` is the on-chain translation: proportional economic
friction, event trail, participant not excluded.

`riskLevel`: 0–30 → `STANDARD` · 31–70 → `ELEVATED` · 71–100 → `BLOCK`.

---

## Step 3: Evidentiary sufficiency (REVERT 71–99)

| Control | Criterion | On failure |
|---|---|---|
| **At least one HIGH fact** | Score cannot rest only on MEDIUM/LOW | Flag `INSUFFICIENT_CONFIDENCE`; degrade to `FEE_OVERRIDE` |
| **FATF category multiplicity** | At least two concurrent categories | Warning; human review before consolidating as policy on that wallet |
| **No critical gap** | No case-file gap blocks the dimension supporting the block | Degrade to `FEE_OVERRIDE`; record limitation |
| **Own fact or verified signal** | Block not based solely on unverified external signals | Degrade to `FEE_OVERRIDE`; see `cross-pool-intelligence` |

These controls do **not** apply to Step 1 overrides.

---

## Step 4: FEE_OVERRIDE destination

FEE_OVERRIDE is not credited to the pool immediately. It deposits to an escrow
contract with configurable timelock (default 48 hours).

| Scenario within timelock | Fee destination |
|---|---|
| Wallet confirmed in a fraud scheme (later designation, linked wallets, completed pattern) | Compensation fund for affected LPs |
| No confirmation at expiry | Normal release to the pool |

Every escrow deposit records the `auditHash` of the supporting `ScoreResult`.

---

## Step 5: Reason basis

Every decision, including `ALLOW`, produces a registrable basis. Inaction is
also a decision under reasonable-monitoring standards.

Basis includes:

1. `finalScore` and applied band
2. Top three facts by `scoreContribution`, with `regulatoryBasis`
3. Typologies and concurrent FATF category count
4. Sufficiency controls passed or failed
5. Score calculation time / execution block (live)
6. `auditHash`

**Length rule.** On-chain emit = identifier + reason code, not long text. Full
basis stays off-chain, linked by `auditHash`.

---

## Step 6: Derivations

| Condition | Derivation |
|---|---|
| Active sanctions override | `task-blocking-protocol`, critical |
| `REASONABLE_SUSPICION_REACHED` | `task-regulatory-report` |
| `REVERT` for score 71–99 | `task-regulatory-report` |
| `INSUFFICIENT_CONFIDENCE` or critical gap | Human review by operator Compliance Officer |
| `FEE_OVERRIDE` without reasonable suspicion | Record and monitor; no formal case file |
| `ALLOW` | Verification record; close |
| Publishable own fact | `cross-pool-intelligence` (publish) |
| Challenge on this decision | `dispute-remediation` |
| Included in validation period | `model-validation` |

---

## Structured output

```json
{
  "eventId": "...",
  "address": "0x...",
  "finalScore": 0,
  "riskLevel": "STANDARD | ELEVATED | BLOCK",
  "hookOutput": "ALLOW | FEE_OVERRIDE | REVERT",
  "overrideApplied": { "active": false, "rule": null },
  "sufficiencyValidation": {
    "highFactPresent": true,
    "ownOrVerifiedSupport": true,
    "concurrentFatfCategories": 0,
    "criticalGap": false,
    "result": "sufficient | degraded | insufficient",
    "degradedFrom": null
  },
  "fee": {
    "multiplierApplied": 1,
    "escrow": false,
    "timelockHours": null,
    "escrowId": null
  },
  "basis": {
    "reasonCode": "...",
    "mainFacts": [
      {"type": "...", "scoreContribution": 0, "regulatoryBasis": "..."}
    ],
    "typologies": ["..."],
    "auditHash": "..."
  },
  "requiresHumanReview": false,
  "challengePathAvailable": true,
  "nextSkill": "task-blocking-protocol | task-regulatory-report | cross-pool-intelligence | close"
}
```

> Produces an execution decision on an operation, not a conclusion on the
> lawfulness of anyone’s conduct. Qualifying an operation as suspicious, and
> any derived action, belongs to the pool Compliance Officer.
