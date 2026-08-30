---
name: dispute-remediation
description: "Manage score challenges and system-error correction. Covers the LP-report challenge period, disputes from a blocked wallet, review on new evidence, profile rehabilitation, treatment of FEE_OVERRIDE fees charged on a reversed score, and sanctions for malicious reports. Use on every challenge, when evidence contradicts a current score, and periodically to review sustained blocks."
---

# Dispute and Remediation: Challenge and Correction

## Role

A system that blocks and cannot unblock fails the risk-based approach:
proportionality requires lifting the measure when the founding risk disappears
or is shown nonexistent.

This skill closes the loop. Without it the pack produces irreversible
decisions on participants with no correction path.

**Demo runtime:** no live LP (liquidity provider)-report challenge UI (user
interface). This skill is the product spec for a later operator loop. Score
changes in UHI10 come from new Anvil facts (P2P (peer-to-peer),
`SwapObserved`, `WalletBlocked`), not from a dispute ticket.

---

## Expected inputs

| Field | Description |
|---|---|
| `challengeType` | LP report in challenge, score dispute, new-evidence review, periodic review |
| `address` | Affected address |
| `challengedScore` | `ScoreResult` under review, with `auditHash` |
| `challengedFacts` | Triggering facts whose validity is questioned |
| `submittedEvidence` | Material supporting the challenge |
| `challenger` | Wallet holder, reported LP, operator, or the system |
| `associatedEscrow` | Escrow id if FEE_OVERRIDE was collected |

---

## Step 1: Standing and admissibility

| Challenger | May challenge | May not challenge |
|---|---|---|
| **Wallet holder** | Own score, constituent facts, failed attribution | Direct official-list sanctions match |
| **Reported LP** | Report received during challenge period | Score built on other dimensions |
| **Pool operator** | Any score on their pool | Sanctions overrides |
| **System** | Any score on new evidence or source-error correction | n/a |

**Non-challengable matter.** An override from an official-list designation is
not disputed before the pool operator or the agent. Challenge the designation
before the issuing authority via its delisting procedures. Inform and close
without analyzing.

**Proof of control.** Challenger must prove control of the address by signing
a message with the corresponding key. Without that proof, challenge is not
admitted.

---

## Step 2: LP-report challenge period

LP reports are the most manipulable source. The challenge period is the control.

| Stage | Content | Default timing |
|---|---|---|
| Receipt | Report registered; does not affect score | Immediate |
| Notice | Reported wallet learns of the report fact, without complainant identity | Immediate |
| Challenge | Wallet may submit contradicting evidence | 72 hours |
| Resolution | Agent evaluates report and response | 24 hours |
| Effect | If sustained, fact enters score | On resolve |

**Integrity rules.**

1. A single report never changes the score. Need configured independent-report threshold.
2. Reports from LPs linked by common funding/co-spend count as one.
3. Effect ceiling is the `FEE_OVERRIDE` band. Never block alone.
4. Reports decay over time.

**Malicious-report sanction.** If resolution finds the report baseless and
coordinated, execute complainant stake per pool policy and record on the
complainant’s profile. Without cost for false reports, the mechanism becomes
an attack vector against competitors.

---

## Step 3: Score dispute

| Cause | Content | Effect if succeeds |
|---|---|---|
| **Fact error** | Triggering fact did not occur, or on-chain evidence does not support it | Remove fact; recalculate |
| **Attribution error** | Address wrongly linked to a cluster or wallet | Remove link; recalculate |
| **Economic explanation** | Verifiable legitimate justification of the pattern | Degrade confidence or discard per `typology-detection` Step 2 |
| **Incorrect source** | Analytics provider corrected attribution | Update fact with new information |
| **Expiry** | Fact outside analysis window; decay not applied | Recalculate with correct decay |
| **Failed attribution** | Actor proves they were the originator of an attribution-blocked op | Resolve attribution; build profile |

**Standard of proof.** Challenge must bring verifiable evidence, preferably
on-chain. Unsupported assertion does not reverse a documented fact. Burden on
challenger, except fact error (enough to show cited evidence missing or
misstated).

---

## Step 4: FEE_OVERRIDE remediation

If a score that founded a `FEE_OVERRIDE` is reversed while the differential fee
is still Active in `FeeEscrow`:

| Outcome | Escrow treatment |
|---|---|
| Score reduced to ALLOW band | Keeper may `releaseEarly` to `lpCompensationFund` (never the pool; never refund to the swap subject as default) |
| Score remains ELEVATED on other sustained facts | Escrow follows Checkpoint 1/2 rules |
| Challenge frivolous | Escrow continues; optional challenger cost |
| Later illicit confirmation at Checkpoint 2 | Publish list/score ≥ 71, then `resolveCheckpoint2` → Blocked; later recover* → ComplianceTreasury `ILLICIT_RISK_FEE` (risk fee) or `LP_PRINCIPAL` (seized capital) |

Every remediation records original and new `auditHash`. The COA (Compliance
Officer Agent) recommends; only the FeeEscrow keeper writes.
---

## Step 5: Periodic review of sustained blocks

Default every 90 days for non-sanctions blocks. Re-check founding facts still
valid; if not, recalculate and potentially rehabilitate.

Sanctions overrides: not lifted here. Lift only on list delisting / operator
legal instruction consistent with OFAC (Office of Foreign Assets Control)
duties.

---

## Structured output

```json
{
  "challengeType": "...",
  "address": "0x...",
  "admissible": true,
  "resolution": "sustained | overturned | partially_overturned | closed_non_challengable",
  "factsRemoved": [],
  "factsUpdated": [],
  "priorFinalScore": 0,
  "newFinalScore": 0,
  "priorHookOutput": "FEE_OVERRIDE",
  "newHookOutput": "ALLOW",
  "escrowAction": "none | release | continue",
  "auditHashPrior": "...",
  "auditHashNew": "...",
  "requiresHumanReview": false,
  "notes": "..."
}
```
