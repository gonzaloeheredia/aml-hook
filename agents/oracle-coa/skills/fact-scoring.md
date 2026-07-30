---
name: fact-scoring
description: "AML/CFT wallet scoring module (score 0–100) with FATF/OFAC/BSA justification per dimension. Produces the score AML Hook consumes at beforeSwap for ternary output: ALLOW, FEE_OVERRIDE, or REVERT. Use whenever task-swap-decision needs a quantified rating integrable into the task-regulatory-report Opinion pack. Spec implemented by backend/src/oracle/factScoring.ts (MOCK_MODE)."
---

# Fact Scoring — Wallet AML/CFT Scoring Module

## Purpose and scope

Risk-evaluation engine for the AML Hook Compliance Officer Agent. Takes
observed facts about an address and translates them into a numeric risk score
(0–100) with audited normative traceability, ready to write to the oracle and
consume at swap time.

Each weight derives from FATF recommendations / technical papers, applied
under BSA / OFAC (U.S.) and MiCA / TFR (EU). The module does not invent
arbitrary scores.

Outputs serve two functions:

1. **On-chain / oracle.** `finalScore` is signed (live) and written to
   `ComplianceOracle` / the demo oracle store. `AMLHook.beforeSwap` reads it
   and applies ternary output without extra latency.
2. **Documentary.** Full `ScoreResult` is a mandatory section of the Opinion
   pack from `task-regulatory-report`.

**Architectural constraint.** Off-chain and asynchronous relative to the swap.
The hook never invokes this module at runtime; it reads a precomputed score.

**Demo backbone.** For the UHI10 A/B/C ledger, N-hop contamination uses
`derived_score = origin_score × (0.65 ^ hops)`. When hop facts dominate,
`factScoring.ts` aligns `finalScore` to that formula for demo fidelity.

---

## Reference framework (summary)

| Source | Role in scoring |
|---|---|
| FATF Rec. 1 (RBA) | Continuous 0–100 score; proportional ternary controls |
| FATF Rec. 10 | Continuous monitoring; mid-band = functional EDD |
| FATF Rec. 15 / 16 | VA/VASP risks; Travel Rule is perimeter/mitigant, not a swap duty |
| FATF Rec. 20 | Reasonable suspicion (not certainty); no minimum amount |
| FATF VA Red Flags 2020 | Six categories; multiplicity principle → context multipliers |
| OFAC / BSA / MiCA / TFR / AMLR | Application frameworks for screening, SAR support, CASP |

Travel Rule does **not** attach to the swap itself (no two institutions, no
distinct originator/beneficiary, user keeps custody). Prior-leg IVMS 101 may
act as a mitigant (`TRAVEL_RULE_PRIOR_LEG`).

---

## 1. Input structure

```json
{
  "wallet": {
    "address": "0x...",
    "chainId": 1,
    "accountType": "EOA | SMART_ACCOUNT | UNKNOWN",
    "controllers": ["0x..."],
    "firstSeenBlock": 0,
    "ageDays": 0
  },
  "swap": {
    "poolId": "0x...",
    "amountSpecified": "0",
    "zeroForOne": true,
    "estimatedUsd": 0.0,
    "blockTimestamp": "<ISO 8601>"
  },
  "facts": ["<FactEvent>", "..."]
}
```

Each `FactEvent` (keys match `backend/src/oracle/types.ts`):

```json
{
  "factId": "<unique id>",
  "type": "<catalog type>",
  "confidence": "HIGH | MEDIUM | LOW",
  "baseWeight": 0,
  "scoreContribution": 0,
  "regulatoryBasis": "<FATF / OFAC / BSA / MiCA cite>",
  "justification": "<natural language>",
  "dimension": "S | ST | MX | NW | GEO | MT | DF"
}
```

**Confidence:** `HIGH` = official list or confirmed on-chain tx; `MEDIUM` =
analytics-derived or computed on verified data; `LOW` = statistical inference
without independent confirmation.

**Admissibility.** No `LOW` inference-only fact may be the sole support for
score ≥ 71. The block band requires at least one `HIGH` fact.

---

## 2. Fact catalog by dimension

### 2.1 S — Sanctions (override capable)

| Type | Description | baseWeight |
|---|---|---|
| `OFAC_DIRECT_MATCH` | Exact address on OFAC SDN | +100 (override) |
| `UN_DIRECT_MATCH` | UN Security Council list | +100 (override) |
| `EU_DIRECT_MATCH` | EU consolidated list | +100 (override) |
| `SANCTIONED_CONTRACT_DIRECT` | Direct interaction with designated contract | +100 (override) |
| `TERRORISM_FINANCING` | Documented TF / proliferation nexus | +100 (override) |
| `INDIRECT_COUNTERPARTY_MATCH` | Direct counterparty on a list | +50 |
| `SANCTIONED_CLUSTER_LINK` | Analytics cluster → designated entity | +45 |

### 2.2 ST — Structuring

FATF VA Red Flags Cat. 1.

| Type | Description | baseWeight |
|---|---|---|
| `STRUCTURING_THRESHOLD_PROXIMITY` | Amount 80–99% of report threshold | +15 |
| `STRUCTURING_SPLIT_PATTERN` | N swaps in window T; sum ≥ threshold; none alone exceeds | +25 |
| `STRUCTURING_ROUND_AMOUNT` | Exact round amounts + high frequency | +10 |
| `STRUCTURING_VELOCITY_SPIKE` | Period volume > 5× historical mean | +20 |
| `STRUCTURING_CROSS_WALLET` | Coordinated smurfing across linked wallets | +35 |
| `STRUCTURING_STEPPED_PATTERN` | Rapid high-value series then long idle | +18 |
| `STRUCTURING_UNILATERAL_DIRECTIONAL` | Constant `zeroForOne`, homogeneous amounts | +15 |

Defaults: report threshold USD 10,000; window 30 days; min splits 3.

### 2.3 MX — Mixers / anonymization

FATF Cat. 3; OFAC VC Guidance 2021. Lookback default 90 days.

| Type | Description | baseWeight |
|---|---|---|
| `MIXER_DIRECT_INTERACTION` | Direct interaction with non-designated mixer | +30 |
| `MIXER_INDIRECT_INTERACTION` | Funds from a mixer-touched wallet | +20 |
| `MIXER_POST_TIMING` | Swap within 72h after mixer interaction | +15 |
| `PRIVACY_COIN_UNJUSTIFIED` | Privacy-coin conversion without economic correlative | +20 |
| `BRIDGE_CHAIN_HOPPING` | ≥3 chains in <24h before swap | +22 |
| `OPAQUE_ORIGIN_MAJORITY` | >50% inbound funds unattributable | +25 |

### 2.4 NW — Network / counterparties

FATF Cats. 2, 4, 5; Rec. 10. **Demo types used by the mock:**

| Type | Description | baseWeight |
|---|---|---|
| `HIGH_RISK_COUNTERPARTY` | Direct counterparty / hop-1 contamination (score ≥ 71 origin path) | +25 (demo: hop weight) |
| `MEDIUM_RISK_COUNTERPARTY` | Mid-band counterparty / hop ≥ 2 | +10 (demo: hop weight) |
| `EXPLOIT_PROTOCOL_FUNDS` | Traceable to documented exploit / confirmed cash-out source | +35 / override 100 in demo |
| `RAPID_FULL_BALANCE_TRANSFER` | Moves >90% soon after receipt (Cat. 2) | +25 |
| `NEW_WALLET_HIGH_VALUE` | Age <30 days, swap above threshold | +20 |
| `ACCOUNT_AGE_VS_SWAP_SIZE` | Statistical anomaly vs pool distribution | +22 |
| `INBOUND_ONLY_MICRO_CLUSTER` | Small unidirectional inbounds from many addresses | +22 |
| `COUNTERPARTY_CONCENTRATION` | Near-exclusive interaction with target + self wallets | +18 |
| `DARKNET_LINK` / `RANSOMWARE_LINK` | Traceable illicit markets / ransomware | +40 / +45 |
| `LP_REPORT_VALIDATED` | Independent staked LP reports past threshold + challenge | +20 |
| `EXTERNAL_SIGNAL_VERIFIED` | Shared-registry fact independently verified | inherits |
| `EXTERNAL_SIGNAL_UNVERIFIED` | Shared-registry, unverified; ceiling at FEE_OVERRIDE | × 0.5 |
| `ATTRIBUTION_INCONSISTENT` | Unsigned hookData originator ≠ effective fund recipient | +20 |

### 2.4 bis DF — Native DeFi typologies

Aggregated into NW for totals when needed. Receive-vs-use rule applies to all.

| Type | baseWeight |
|---|---|
| `SWAP_INTERNAL_CLAIMS_6909` | +25 |
| `SANDWICH_EXTRACTION` | +18 |
| `FLASH_LOAN_MANIPULATION` | +30 |
| `RUG_PULL_LIQUIDITY_REMOVAL` | +35 |
| `WASH_TRADING_LP` | +25 |
| `APPROVAL_DRAIN` | +40 |
| `ADDRESS_POISONING` | +30 |
| `NFT_LAYERING` | +22 |
| `CEX_CHAIN_JUMP` | +20 |
| `INVESTMENT_SCAM_PRODUCT` | +35 |
| `STATE_EVASION_PATTERN` | +45 |

### 2.5 GEO — Geographic risk

Inference only; max confidence `MEDIUM` unless analytics documents attribution.

| Type | baseWeight |
|---|---|
| `GEO_FATF_BLACKLIST` | +30 |
| `GEO_FATF_GREYLIST` | +15 |
| `GEO_COMPREHENSIVE_SANCTIONS_REGIME` | +35 |
| `GEO_UNREGULATED_SERVICE` | +15 |

### 2.6 MT — Mitigants

Never below 0; never neutralize a sanctions override. **Cap: 40 points.**

| Type | baseWeight |
|---|---|
| `LONG_CLEAN_HISTORY` | −10 |
| `COHERENT_TRANSACTION_PROFILE` | −8 |
| `TRAVEL_RULE_PRIOR_LEG` | −10 |
| `VERIFIED_INSTITUTIONAL_COUNTERPARTY` | −12 |
| `VALID_THIRD_PARTY_ATTESTATION` | −12 |
| `PREREGISTERED_SMART_ACCOUNT` | −15 |
| `HIGH_PROTOCOL_DIVERSITY` | −8 |

---

## 3. Scoring algorithm

### 3.1 Per-dimension score

For each dimension D ∈ {S, ST, MX, NW, GEO, MT, DF}:

```
raw_score_D = Σ (baseWeight_i × confidence_modifier_i × context_multiplier_i)
```

**Confidence modifier:** HIGH ×1.0 · MEDIUM ×0.85 · LOW ×0.60

**Context multiplier** (additive, not multiplicative stack; max practical ~1.6):
recurrent same type in 30d ×1.3; same-dimension combination ×1.2; multi-source
verification ×1.1.

### 3.2 Aggregate

```
raw_total = S + ST + MX + NW + GEO + DF − min(MT, 40)
finalScore = clamp(raw_total, 0, 100)
```

Any S-dimension override fact → `finalScore = 100` without other dimensions.

### 3.3 Historical blend

```
finalScore = (priorScore × decay_factor) + (presentScore × (1 − decay_factor))
```

Default `decay_factor = 0.4` (40% history / 60% present). No prior → 0.0.
Mock skips blend when hop distance dominates (demo fidelity).

### 3.4 afterSwap-triggered update

1. `afterSwap` emits `SwapObserved`
2. Engine incorporates event into wallet history
3. Re-evaluate ST / NW on updated window
4. Recompute `finalScore`
5. Write signed result to oracle
6. Next `beforeSwap` reads updated score

Declare calculation time in `validity.calculatedAt` (and block number when live).

### 3.5 Manipulation resistance

1. Do not publish effective per-pool threshold values (output bands are public).
2. `LP_REPORT_VALIDATED` alone cannot reach the block band (FEE_OVERRIDE ceiling).
3. Mitigant aggregate cap = 40.
4. Governable parameter changes via DAO Timelock only.

---

## 4. Module output (`ScoreResult`)

Keys **must** match `backend/src/oracle/types.ts`:

```json
{
  "walletId": "A",
  "address": "0x...",
  "finalScore": 0,
  "riskLevel": "BLOCK | ELEVATED | STANDARD",
  "hookOutput": "REVERT | FEE_OVERRIDE | ALLOW",
  "scoreBreakdown": {
    "sanctions": 0,
    "structuring": 0,
    "mixerExposure": 0,
    "networkBehavior": 0,
    "geographicRisk": 0,
    "defiTypologies": 0,
    "mitigants": 0,
    "historicalComponent": 0
  },
  "triggeringFacts": [
    {
      "factId": "<id>",
      "type": "<type>",
      "confidence": "HIGH | MEDIUM | LOW",
      "baseWeight": 0,
      "scoreContribution": 0,
      "regulatoryBasis": "<cite>",
      "justification": "<text>",
      "dimension": "S | ST | MX | NW | GEO | MT | DF"
    }
  ],
  "regulatoryFlags": [
    {
      "type": "REASONABLE_SUSPICION_REACHED | EDD_REQUIRED | OFAC_BLOCK | HUMAN_REVIEW_REQUIRED | INSUFFICIENT_CONFIDENCE | ATTRIBUTION_FAILED | EXTERNAL_SUPPORT_INSUFFICIENT | CHALLENGE_PENDING",
      "description": "<text>",
      "recommendation": "<action>"
    }
  ],
  "validity": {
    "calculatedAt": "<ISO 8601>",
    "trigger": "seed | transfer | afterSwap | blocked | manual",
    "nextReview": "<ISO 8601>"
  },
  "auditHash": "<hash>",
  "skillsApplied": ["task-swap-intake", "..."],
  "flow": "FULL | INCREMENTAL"
}
```

### 4.1 Score → hook output

| Range | riskLevel | hookOutput | Basis |
|---|---|---|---|
| 0–30 | `STANDARD` | `ALLOW` | FATF Rec. 1 & 10 — proportional controls |
| 31–70 | `ELEVATED` | `FEE_OVERRIDE` | Rec. 10 EDD — economic friction, not hard block |
| 71–99 | `BLOCK` | `REVERT` | Rec. 20 / BSA — reasonable suspicion |
| 100 | `BLOCK` | `REVERT` + blocking protocol | Rec. 6 / IEEPA — unconditional designation path |

**71–99 vs 100.** Mid-block is operation rejection. Score 100 from sanctions
is **blocking** (segregate/audit trail under OFAC), not a simple refund —
see `task-blocking-protocol`.

### 4.2 Reasonable suspicion

Emit `REASONABLE_SUSPICION_REACHED` when `finalScore ≥ 65` **and** at least
two non-mitigant facts (distinct dimensions preferred). The agent never files;
the Compliance Officer decides.

### 4.3 Next review guidance

| Score | nextReview |
|---|---|
| 0–20 | 90 days |
| 21–50 | 30 days |
| 51–70 | 7 days |
| ≥ 71 | immediate / continuous |

### 4.4 Confidence degradation (mock + live)

If `finalScore ≥ 71` without any HIGH contributing fact → degrade to 70 /
`FEE_OVERRIDE` and flag `INSUFFICIENT_CONFIDENCE`.

---

## 5. Mock implementation notes

`backend/src/oracle/factScoring.ts` implements a deterministic subset:

- `EXPLOIT_PROTOCOL_FUNDS` → score 100 override (wallet A)
- Hop contamination → `HIGH_RISK_COUNTERPARTY` / `MEDIUM_RISK_COUNTERPARTY`
  with weight `100 × 0.65^hops`, plus optional `RAPID_FULL_BALANCE_TRANSFER`
- Clean path → `LONG_CLEAN_HISTORY` + `COHERENT_TRANSACTION_PROFILE`
- Optional low-weight `STRUCTURING_VELOCITY_SPIKE` on repeated SwapObserved

Live catalog types above remain the full product spec; the mock covers the
demo ledger path without vendor APIs.
