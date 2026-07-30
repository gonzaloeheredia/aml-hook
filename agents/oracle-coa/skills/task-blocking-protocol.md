---
name: task-blocking-protocol
description: "Execute the protocol when a sanctions match, terrorism-financing nexus, or situation beyond autonomous agent resolution is detected. Covers blocked-funds treatment, segregation with audit trail, notification to the operator Compliance Officer, and confidentiality restrictions. Use immediately on any sanctions-dimension override, without waiting for analysis close."
---

# Task: Blocking Protocol — Block, Segregation, and Notification

## Role

Decides what happens to the operation and funds when analysis yields a result
the agent cannot resolve alone. Does not re-evaluate substance: ensures the
correct action executes and the correct information reaches the correct
recipient on time. Prevents the agent from operating outside its mandate.

---

## Fundamental distinction: reject ≠ block

| Situation | Correct treatment | Incorrect treatment |
|---|---|---|
| Score 71–99 without designation | **Reject.** Swap reverts; funds remain with the participant | — |
| Sanctions list match | **Block.** Funds owed to the designated party are blocked and segregated with an audit trail | Revert and return funds (disposition of blocked property) |

Under OFAC, when a payment/delivery obligation exists toward a designated
party, the asset must be blocked and kept segregated. Returning it to the
sender may itself be a violation. Custody-contract logic belongs to the hook
architecture.

**Scope warning.** Applicability of blocking to a pool operator depends on
regulatory qualification and jurisdictional nexus — preliminarily assessed by
`protocol-obligations`, confirmed by operator counsel. This skill implements
the stricter standard by default and records the criterion applied.

---

## Expected inputs

| Field | Description |
|---|---|
| `eventId` | Event identifier |
| `address` | Affected address |
| `trigger` | What activated the protocol |
| `ofacOutput` | Sanctions screening result |
| `scoreResult` | Full `ScoreResult` |
| `swap` | Affected operation parameters |
| `poolConfig` | Custody policy, segregation contract, operator contacts |

---

## Step 1: Trigger classification

| Trigger | Urgency | Action on operation |
|---|---|---|
| Direct OFAC SDN / UN / EU match | Critical | `REVERT` + custody on affected funds |
| Designated-contract interaction | Critical | Same |
| TF / proliferation nexus | Critical | Same + immediate notification |
| Designated Smart Account controller | Critical | Preventive `REVERT`; custody subject to human review |
| Cluster-attribution match | High | `REVERT`; custody subject to prior human review |
| Active exploit on the pool | Critical | Circuit breaker per operator config |
| Level-1 evidence unavailable | High | Apply default policy; notify operational incident |

Demo: confirmed exploit cash-out (wallet A) → `hookOutput: REVERT`,
`WalletBlocked` recorded; agent still refreshes Opinion via trigger `blocked`.

---

## Step 2: Funds treatment

| Scenario | Treatment |
|---|---|
| Block in `beforeSwap`; tx reverts entirely | No value transfer. Nothing to segregate. Record denial with basis |
| Block detected in `afterSwap` on recipient | Route designated-party balance to custody contract. Do not revert to sender without Compliance Officer instruction |
| Funds credited before designation | Outside hook scope. Notify operator for own process |

**Custody record requirements.** Affected address, amount, asset, block,
`tx_hash`, list and entry supporting the block, `auditHash` of `ScoreResult`.
Asset stays segregated until documented instruction.

---

## Step 3: Notification

Recipient is always the pool operator’s Compliance Officer. The agent does
not contact authorities or third parties.

| Situation | Recipient | Timing |
|---|---|---|
| Confirmed sanctions match | Compliance Officer | Immediate |
| TF financing nexus | Compliance Officer + operator leadership | Immediate |
| Cluster or controller match | Compliance Officer | Same day |
| Reasonable suspicion without designation | Compliance Officer | Same business day |
| Source operational incident | Operator technical owner | Immediate |

---

## Step 4: Confidentiality

- Tip-off prohibition: do not inform the subject of the analysis, report, or
  block rationale beyond what the on-chain revert necessarily reveals.
- Do not publish effective internal thresholds.
- Do not file with OFAC/FinCEN — prepare material for the Compliance Officer.

---

## Step 5: Continuity

After block:

1. Write / refresh oracle score (`finalScore` 100 / `hookOutput` REVERT).
2. Produce Opinion + SAR-support annex via `task-regulatory-report`.
3. Watch outbound P2P for contamination of downstream wallets (demo B/C).
4. Periodic review of sustained blocks per `dispute-remediation` / config
   (default 90 days) — except active sanctions overrides (not disputable here).

---

## Structured output

```json
{
  "eventId": "...",
  "address": "0x...",
  "trigger": "...",
  "hookOutput": "REVERT",
  "finalScore": 100,
  "custody": {
    "activated": false,
    "reason": "beforeSwap full revert — no asset to segregate | custody routed | pending human review"
  },
  "notifications": [{"recipient": "compliance_officer", "timing": "immediate"}],
  "auditHash": "...",
  "nextSkill": "task-regulatory-report",
  "requiresHumanReview": true,
  "tipOffProhibited": true
}
```
