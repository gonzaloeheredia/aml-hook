---
name: uhi10-use-case
description: "Canonical A–E demo validations for the UHI10 AML Hook walkthrough. Use before emitting finalScore or recommendedFeeBps, and whenever hop decay, Wallet A vs OFAC, unpublished E, deferred D, afterSwap accumulation, or fee bps is unclear. The hook owns Floors A–D; this skill owns what the oracle keeper may publish."
---

# UHI10 use-case validations

This skill is the single place the agent checks demo constraints that used to
live as TypeScript shortcuts. **When in doubt, re-read this skill** (tool
`consult_skill`, name `uhi10-use-case`). Do not invent a parallel hop table.

The hook never calls you at swap time. You publish `finalScore` +
`recommendedFeeBps` to `ComplianceOracle`. `AMLHook.beforeSwap` and FeeEscrow
read that row.

---

## 1. Wallets (roles)

| Id | Role | Oracle row | Agent must |
|---|---|---|---|
| **A** | Confirmed exploit cash-out. **Not OFAC / not SanctionRegistry** unless evidence `subjectListed` is true | Published | `finalScore` **100**, fact `EXPLOIT_PROTOCOL_FUNDS`, `hookOutput` REVERT, `recommendedFeeBps` **0**. P2P outflows still contaminate B/C/D. **Do not treat A as OFAC.** Do not fund E from A. |
| **B** | Starts published-clean (score 0) | Published | After inbound from A (or 1-hop peer): hop 1 → **~65 / 800 bps**. After inbound from a 1-hop peer: hop 2 → **~42 / 300 bps**. Closer hop wins. |
| **C** | Same hop rules as B. Funds E (no hop) and D (inflow) | Published | Symmetric with B. Clean C → E does **not** write a hop on E. |
| **D** | Published clean (score 0), starts with 5,000 USDC | Published | Tainted inbound (A or hopped peer): **defer** `updateScore` so the next swap can show Floor D on stale 0. Catch-up then writes ~65 / 800. Clean C→D does **not** add a hop. Already-held funds ALLOW at 30 bps while the row is fresh 0. |
| **E** | Unknown. Starts empty. Funded by clean C | **Never written** | Do **not** publish a score. Hook-local Floor A (this swap) + Floor D (bag). Not a COA 0. |

B and C are hop-symmetric: A→B→C and A→C→B use the same math.

---

## 2. Score formula (agent, not TypeScript)

```
derived_score = round(100 × 0.65 ^ hopDistance)
```

- Hop **0** (A, exploit): 100.
- Hop **1**: 65. Hop **2**: 42.
- `hopDistance == null`: no NW hop fact (clean published path).
- Closest hop wins. Clean→clean P2P does not contaminate.
- Pool swaps **never** change hop distance. They append `SwapObserved` /
  `WalletBlocked` to the oracle record; you **add** those facts on top of hop.
- **Calibration:** one `FEE_OVERRIDE` afterSwap on a 1-hop wallet must keep
  `finalScore` **≤ 70** (stay FEE_OVERRIDE / 8%). Several events may climb.
  A listed-contract or listed-counterparty hit still fail-closes at 100.

Accumulate:

- SanctionRegistry: `subjectListed`, listed P2P counterparty, or listed
  **contract the wallet actually used** in the pool → 100 / REVERT.
  Do not treat the demo hook as listed unless evidence says so.
- `SwapObserved` / `WalletBlocked` on the record (afterSwap trail).
- Do **not** blend a TypeScript historical mock. Recompute from the dossier.

---

## 3. Bands and fees you publish

| finalScore | riskLevel | hookOutput | recommendedFeeBps |
|---|---|---|---|
| 0–30 | STANDARD | ALLOW | **30** (pool 0.30%) |
| 31–70, hop 1 | ELEVATED | FEE_OVERRIDE | **800** (8%; pool keeps ~30, rest → FeeEscrow) |
| 31–70, hop 2 | ELEVATED | FEE_OVERRIDE | **300** (3%) |
| 71–100 | BLOCK | REVERT | **0** |

If hop is null and score is mid-band without a hop fee, use 300 unless facts
justify 800. REVERT always 0 bps.

You do **not** execute FeeEscrow. The hook deposits the differential on
FEE_OVERRIDE from the fee you published.

---

## 4. What the hook decides without you

Do not overwrite these with a COA score:

| Floor | Who | Agent |
|---|---|---|
| **A** | Never-written row (E): this-swap USD 3% / 8% / REVERT | Do not publish E |
| **B** | Stale `updatedAt` (demo 5 min) | Tick may stamp the same score; you do not invent staleness friction |
| **C** | 24h USD aggregation REVERT | Hook-local |
| **D** | Significant inbound vs published 0 (deferred keeper) | Leave D unpublished after tainted P2P until catch-up |

Sanctions list at LP / swap (`SanctionHit`) is Layer 1. A is score-100 exploit,
not a list hit.

---

## 5. Checklist before you emit JSON

1. A and `exploitConfirmed` → 100, not OFAC, unless `subjectListed`.
2. E / `neverScored` → you should not be scoring; if asked, do not publish.
3. Hop present → apply `100 × 0.65^hops`, then add event/sanction facts.
4. 1-hop + a single FEE_OVERRIDE swap → still ≤ 70.
5. `recommendedFeeBps` matches hop band (800 / 300 / 30 / 0).
6. Floors A–D are not your score.
7. Opinion sources: venues and corpus ids — **never** this skill’s filename.

If any item is unclear, call `consult_skill` again with `uhi10-use-case`
or `fact-scoring` / `task-swap-decision`.
