---
name: task-blocking-protocol
description: "Execute the protocol when a sanctions match, terrorism-financing nexus, or situation beyond autonomous agent resolution is detected. Covers beforeSwap REVERT, FeeEscrow (FEE_OVERRIDE differential only), notification to the operator Compliance Officer, and confidentiality restrictions. Use immediately on any sanctions-dimension override, without waiting for analysis close."
---

# Task: Blocking Protocol: Revert, Notification, and Fee Hold

## Role

Decides what happens to the operation when analysis yields a result the agent
cannot resolve alone. Does not re-evaluate substance: ensures the correct
action executes and the correct information reaches the correct recipient on
time. Prevents the agent from operating outside its mandate.

---

## Fundamental distinction: REVERT ≠ OFAC (Office of Foreign Assets Control) blocked property

| Situation | Correct treatment | Incorrect treatment |
|---|---|---|
| Score 71–100 or sanctions match at swap time | **REVERT in `beforeSwap`.** The swap never confirms. No value transfer. Nothing to segregate on-chain. | Route swap output to a custody contract (afterSwap never holds principal) |
| Score 31–70 (`FEE_OVERRIDE`) | Swap executes. Pool keeps the standard LP (liquidity provider) fee; **FeeEscrow holds only the risk differential** (not user capital, not designated-party property). | Treat FeeEscrow as OFAC blocked-property custody |
| Funds already moved outside the pool (P2P (peer-to-peer), prior credit) | Outside hook scope. Notify the operator Compliance Officer. | Invent an on-chain freeze the hook cannot perform |

Under OFAC, when a payment/delivery obligation exists toward a designated
party, the asset must be blocked and kept segregated. Returning it to the
sender may itself be a violation. **AML Hook does not create that obligation:**
a list match fails closed in `beforeSwap`, so no delivery arises and there is
no asset to segregate. Operator-level blocked-property duties, if they apply,
sit with the operator, not with a hook custody contract.

FeeEscrow is unrelated to that OFAC path. It holds the extra risk slice
(and, on a blocked LP exit, seized principal) for 48 hours (whitepaper §8.3).
The COA (Compliance Officer Agent) never writes FeeEscrow. The FeeEscrow
keeper submits the on-chain call after a sanity check. A clean risk-fee exit
goes to the LP compensation fund. A clean principal row returns to the LP
wallet. A confirmed-illicit row is recovered to ComplianceTreasury
(`ILLICIT_RISK_FEE` or `LP_PRINCIPAL` by kind).

**Scope warning.** Applicability of blocking obligations to a pool operator
depends on regulatory qualification and jurisdictional nexus. Assessed
preliminarily by `protocol-obligations`, confirmed by operator counsel. This
skill records the criterion applied. It does not instruct the hook to custody
swap output.

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
| `poolConfig` | Operator contacts; FeeEscrow is the only on-chain hold (differential fee) |

---

## Step 1: Trigger classification

| Trigger | Urgency | Action on operation |
|---|---|---|
| Direct OFAC SDN (Specially Designated Nationals) / UN (United Nations) / EU (European Union) match | Critical | `REVERT` in `beforeSwap`. No on-chain custody. |
| Designated-contract interaction | Critical | Same |
| TF (terrorist financing) / proliferation nexus | Critical | Same + immediate notification |
| Designated Smart Account controller | Critical | Preventive `REVERT`; human review of the subject, not asset custody |
| Cluster-attribution match | High | `REVERT`; human review before any later score refresh |
| Active exploit on the pool | Critical | Circuit breaker per operator config |
| Level-1 evidence unavailable | High | Apply default policy; notify operational incident |

Demo: confirmed exploit cash-out (wallet A) → `hookOutput: REVERT`,
`WalletBlocked` recorded; agent still refreshes Opinion via trigger `blocked`.

---

## Step 2: Funds treatment

| Scenario | Treatment |
|---|---|
| `REVERT` in `beforeSwap`; tx reverts entirely | No value transfer. Nothing to segregate. Record denial with basis. |
| `FEE_OVERRIDE` in `afterSwap` | Hook takes the risk differential into FeeEscrow. User swap output settles in-block. Do not describe this as blocked property. |
| Recipient screening in `afterSwap` | **Does not exist.** afterSwap does not evaluate a buyer and does not route principal to custody. |
| Funds credited before designation | Outside hook scope. Notify operator for own process. |

**Record requirements (REVERT).** Affected address, intended amount, asset,
block, `tx_hash` if any, list and entry supporting the denial, `auditHash` of
`ScoreResult`. There is no segregated asset to hold.

**Record requirements (FEE_OVERRIDE).** FeeEscrow deposit: subject, retained
differential, origin `tx_hash`, `FeeDeposited`. Later `FeeReleasedEarly` /
`FeeBlocked` / `FeeReleasedDefault` / `FeeRecovered` complete the trail. A
confirmed sanction blocks the fee in escrow; later recovery pays
ComplianceTreasury `ILLICIT_RISK_FEE` (`FeeRecovered` then `ComplianceCredited`). Fees not confirmed high-risk or sanctioned go to
`lpCompensationFund` (Checkpoint 2 clean and `releaseDefault`), never as OFAC
blocked property, never to LPs after a confirmed sanction, and never back to
the pool.

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
  revert rationale beyond what the on-chain revert necessarily reveals.
- Do not publish effective internal thresholds.
- Do not file with OFAC/FinCEN (Financial Crimes Enforcement Network). Prepare
  material for the Compliance Officer.

---

## Step 5: Continuity

After `REVERT`:

1. Write / refresh oracle score (`finalScore` 100 / `hookOutput` REVERT).
2. Produce Opinion + SAR (Suspicious Activity Report)-support annex via
   `task-regulatory-report`.
3. Watch outbound P2P for contamination of downstream wallets (demo B/C).
4. Periodic review of sustained denials per `dispute-remediation` / config
   (default 90 days), except active sanctions overrides (not disputable here).

After `FEE_OVERRIDE`, FeeEscrow checkpoints are driven by the FeeEscrow
keeper from COA memos (`task-swap-decision` / dispute path). This skill does
not submit those transactions.

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
    "reason": "beforeSwap full revert: no asset to segregate | FEE_OVERRIDE differential in FeeEscrow | pending human review (operator process, not hook custody)"
  },
  "notifications": [{"recipient": "compliance_officer", "timing": "immediate"}],
  "auditHash": "...",
  "nextSkill": "task-regulatory-report",
  "requiresHumanReview": true,
  "tipOffProhibited": true
}
```
