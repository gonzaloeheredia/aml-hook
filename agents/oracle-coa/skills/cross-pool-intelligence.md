---
name: cross-pool-intelligence
description: "Manage the shared-signal registry among pools integrating AML Hook: what is shared, how an external signal is weighted vs an own observation, how corrections propagate, and how a malicious or miscalibrated pool is prevented from contaminating the common registry. Use when incorporating external signals into a wallet profile, when publishing an own signal, and on every correction of a previously shared score."
---

# Cross-Pool Intelligence — Shared Signal Registry

## Role

Network effect is a defensive product asset: a wallet flagged in one pool has
elevated score in others; the registry accumulates intelligence competitors
cannot replicate without real adoption.

The same mechanism is the system’s most severe attack vector. An uncontrolled
shared registry propagates errors at scale, lets a malicious operator degrade
competitors, and turns a local false positive into a global block.

This skill defines what enters the registry, at what weight it exits, and how
it is corrected.

**Demo runtime:** no live multi-pool registry; skill remains in FULL flow as a
no-op / pass-through consult step.

---

## Expected inputs

| Field | Description |
|---|---|
| `operation` | `PUBLISH` or `QUERY` |
| `address` | Address being published or queried |
| `scoreResult` | Own `ScoreResult`, on publish |
| `originPool` | Pool publishing the signal |
| `externalSignals` | Registry signals, on query |
| `poolReputation` | Quality history of each emitting pool |

---

## Step 1: What is shared / not shared

Share verifiable facts, not judgments.

| Shared | Not shared |
|---|---|
| Facts with on-chain evidence (`tx_hash` + block) | Final numeric `finalScore` |
| Fact type and FATF category | `scoreBreakdown` |
| Fact confidence and source | Applied thresholds |
| Observation block | Emitting pool’s weighting methodology |
| Emitting pool id | Complainant identities |
| Observation `auditHash` | Full case file |

**Why exclude the score.** Score applies pool-specific methodology and
competitively sensitive thresholds. Sharing it would force inheritance of
foreign calibration and de facto publish internals. What travels is the
observation; valuation is local.

---

## Step 2: Admission requirements (cumulative)

| Requirement | Content |
|---|---|
| On-chain evidence | Fact points to a concrete tx, independently verifiable |
| Minimum confidence | No `LOW` facts published |
| Non-derived origin | Do not re-publish another pool’s signal as own; cite original |
| Resolved attribution | No signals on addresses whose originator was not attributed |
| Emitter signature | Verifiable operator signature |

**No circularity.** A received signal cannot be re-emitted as own. Each signal
keeps original emitter identity and `auditHash`.

---

## Step 3: External-signal weighting

| Factor | Effect |
|---|---|
| **Independent verifiability** | If consultable pool confirms on-chain evidence itself → treat as own |
| **Emitter confidence** | Inherited; never raised |
| **Emitter reputation** | Adjust per Step 5 quality history |
| **Independence** | N distinct pools on same fact reinforce; N derivatives of one observation do not |
| **Age** | Temporal decay equivalent to own facts |
| **Fact type** | Sanctions facts always verified against the list — never accepted by signal alone |

**Ceiling rule.** Unverified external signals cap at the `FEE_OVERRIDE` band.
A block requires at least one own `HIGH` fact, or an external signal the
consulting pool verified itself against the cited on-chain evidence.

Weight for unverified: original weight × 0.5 (`EXTERNAL_SIGNAL_UNVERIFIED`).

---

## Step 4: Corrections

When an emitter corrects or retracts:

1. Publish correction with reference to original `auditHash`
2. Consulting pools invalidate derived contributions and recalculate
3. Reputation of emitter updates (Step 5)

---

## Step 5: Emitter reputation

Track true-positive / false-positive rates of published signals against later
verification. Reputation below configured threshold → degrade weight or
suspend admission. Reputation is for signal quality, not a public blacklist of
operators in the Opinion pack.

---

## Structured output

```json
{
  "operation": "PUBLISH | QUERY",
  "address": "0x...",
  "admittedSignals": [],
  "rejectedSignals": [],
  "facts": [
    {
      "type": "EXTERNAL_SIGNAL_VERIFIED | EXTERNAL_SIGNAL_UNVERIFIED",
      "dimension": "NW",
      "baseWeight": 0,
      "confidence": "MEDIUM",
      "regulatoryBasis": "FATF Rec. 10 · shared registry observation",
      "justification": "..."
    }
  ],
  "ceilingApplied": "FEE_OVERRIDE | none",
  "notes": "..."
}
```
