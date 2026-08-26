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

**Demo runtime:** `hookOutput` and `recommendedFeeBps` come from the agent's
emitted score (Claude or interpreter). Floors A–D stay on-chain in
`RiskPolicy.decide`. Consult `uhi10-use-case` before emitting A–F fees.

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
| 0–30 | `ALLOW` | Swap at pool standard fee. Verification event emitted |
| 31–70 | `FEE_OVERRIDE` | Swap at pool standard fee; risk differential taken in `afterSwap` → `FeeEscrow` (48h). Monitoring event with basis |
| 71–99 | `REVERT` | Swap reverted. Reason recorded on-chain |
| 100 | `REVERT` + block | Revert + blocking protocol |

**Mid-band rationale.** Band 31–70 = atypical behavior without confirmed
designation. No legal duty to hard-block. The regulatory standard is enhanced
monitoring — `FEE_OVERRIDE` is the on-chain translation: proportional economic
friction, event trail, participant not excluded.

`riskLevel`: 0–30 → `STANDARD` · 31–70 → `ELEVATED` · 71–100 → `BLOCK`.

`recommendedFeeBps` is total intended friction (e.g. 800 = 8%). On-chain split:
pool keeps ~30 bps; escrow holds `recommendedFeeBps − 30` when above standard.

**Never-scored wallets (`updatedAt == 0`) are not this table.** The hook does
not treat a missing row as score 0. It quotes **this swap** to USD-8
(`lastFx` if younger than 30 minutes, else Chainlink) and applies Mitigation A, then Floor D on the unpublished bag (baseline 0
= the whole current bag). The stricter fee wins. Official ETH/USD + USDC/USD on
a live Deploy; `MockUsdFeed` on Anvil. Dollar cuts and 3% / 8% floors below are
deploy defaults; `_COMPLIANCE_OFFICER` may retune them after 48h. Floor C (24h
USD) is a separate REVERT. Demo Wallet E starts empty and is funded by clean
C. After C→E $500 a $500 swap is 3% (A dust). After C→E $10,000 a $1,000 swap
is 8% (A mid; D mid 3% loses). After C→E $15,000 a small swap is 8% (D bag).
Do not fund E from A (exploit origin / score 100).

| Assessed USD | hookOutput | Fee |
|---|---|---|
| < $1,000 (`1_000e8`) | `FEE_OVERRIDE` | 3% (`FeeBps.PROPORTIONAL`) |
| $1,000 – $14,999 | `FEE_OVERRIDE` | 8% (`FeeBps.LATENCY`) |
| ≥ $15,000 (`15_000e8`) this swap | `REVERT` `UnscoredMagnitudeBlocked` | — |
| Prior 24h + this swap ≥ $15,000 | `REVERT` `DailyAggregationBlocked` | Floor C |
| No live round and no `lastFx` within 24h | `REVERT` `MagnitudeQuoteFailed` | fail-closed |

USD is sized from `lastFx` if that round is younger than 30 minutes (no
Chainlink call). Otherwise one live round per token, then `lastFx` until 24h.

Publish an explicit score 0 with a fresh `updatedAt` when the wallet is
confirmed-clean. Until then, do not describe a large first swap as ALLOW.

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

## Step 4: FEE_OVERRIDE destination (`FeeEscrow`)

FEE_OVERRIDE does **not** inflate the pool LP fee via `lpFeeOverride`. Only the
differential risk fee is deposited into `FeeEscrow` under a 48h window. User
swap output settles in-block. The COA has **no** write path on `FeeEscrow`;
the FeeEscrow keeper alone submits transfers after an off-chain sanity check.

| Moment | Keeper call | Destination |
|---|---|---|
| 0–24h | (optional COA; no write) | Still held |
| Checkpoint 1 (≥24h, <48h | `releaseEarly` | `lpCompensationFund` only (never pool; never blocks) |
| Checkpoint 2 ≥48h, list or oracle score ≥ 71 | `resolveCheckpoint2` (no bool) | Blocked in escrow; later `recoverBlocked` / `recoverExpiredBlocked` → ComplianceTreasury `ILLICIT_RISK_FEE` |
| Checkpoint 2 ≥48h, clean on-chain | `resolveCheckpoint2` | `lpCompensationFund` only (never pool) |
| No resolution after window | `releaseDefault` | `lpCompensationFund` only (never pool) |

Every escrow deposit should be linkable to the supporting `ScoreResult`
(`auditHash` / origin tx). `recommendedFeeBps` from this skill is what the
oracle keeper publishes on-chain for the hook to size the differential.

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
