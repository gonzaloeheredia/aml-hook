---
name: uhi10-use-case
description: "Canonical A–F walkthrough for the AML Hook use case (docs/Use_Case.md). Use before emitting finalScore or recommendedFeeBps, and whenever hop decay, Wallet A vs OFAC, Wallet F SanctionHit, unpublished E, deferred D, LP add floors, afterSwap accumulation, or fee bps is unclear. The hook owns Floors A–D; this skill owns what the oracle keeper may publish. For the live Sepolia pool consult uhi10-sepolia."
---

# UHI10 use-case validations

This skill is the agent form of `docs/Use_Case.md`. **When in doubt, re-read
this skill** (tool `consult_skill`, name `uhi10-use-case`). Do not invent a
parallel hop table. On chain `11155111` also consult `uhi10-sepolia`.

The hook never calls you at swap or LP time. You emit `finalScore` +
`recommendedFeeBps`. The keeper publishes that row to `ComplianceOracle`.
`AMLHook.beforeSwap` / `beforeAddLiquidity` and FeeEscrow read it.

Pool swaps **never** raise a hop. Peer-to-peer USDC moves risk. This
walkthrough is swap-centric; LP rules below still bind you when the subject
is an add/remove caller.

---

## 0. Environments (do not collapse)

| | Guided demo (`Use_Case.md`) | Live pool (`uhi10-sepolia`) |
|---|---|---|
| Chain | Anvil `31337` | Ethereum Sepolia `11155111` |
| This API / UI | Wired. Simulator. Quotes = `previewSwap` | Same API when `ORACLE_CHAIN_ID=11155111` (faucet + keeper). Quotes still `previewSwap`. SDK `getDeployment` is 31337-only |
| Pool | `MockPoolManager` | Official Uniswap v4 PoolManager |
| A–E keys | Anvil #1–#5 | Do **not** map these EOAs onto Sepolia |
| New unscoped EOA | Out of demo | Wallet **E** until a keeper writes |

On Anvil: never publish E. Do not fund E from A or F.

On Sepolia: a judge EOA vs the live pool is Floor A/C/D until
`_ORACLE_KEEPER` + attestor write. You do not auto-publish that address.

---

## 1. Wallets (roles)

| Id | Role | Oracle row | Agent must |
|---|---|---|---|
| **A** | Confirmed exploit cash-out. **Not OFAC / not SanctionRegistry** unless evidence `subjectListed` is true | Published | `finalScore` **100**, fact `EXPLOIT_PROTOCOL_FUNDS`, `hookOutput` REVERT, `recommendedFeeBps` **0**. P2P outflows still contaminate B/C/D. **Do not treat A as OFAC.** Do not fund E from A. |
| **B** | Starts published-clean (score 0) | Published | After inbound from A (or 1-hop peer): hop 1 → **~65 / 800 bps**. After inbound from a 1-hop peer: hop 2 → **~42 / 300 bps**. Closer hop wins. |
| **C** | Same hop rules as B. Funds E (no hop) and D (inflow) | Published | Symmetric with B. Clean C → E does **not** write a hop on E. |
| **D** | Published clean (score 0), starts with 5,000 USDC | Published | Tainted inbound (A or hopped peer): **defer** `updateScore` so the next swap can show Floor D on stale 0. Catch-up then writes ~65 / 800. Clean C→D does **not** add a hop. Already-held funds ALLOW at 30 bps while the row is fresh 0. |
| **E** | Unknown. Starts empty. Funded by clean C | **Never written** | Do **not** publish a score. Hook-local Floor A (this swap) + Floor D (bag). Not a COA 0. Any new Sepolia EOA against the live pool is this path until a keeper writes. |
| **F** | Live OFAC SDN ETH address (Garantex or another identifier from the current dump). Not Anvil #6. No demo key | Published (list override) | Exact-address match → COA writes `SanctionRegistry`. Swap fail-closes **`SanctionHit` at Layer 1**, before the score is read. **Not** `WalletBlocked`. Do not hop-contaminate B/C/D from F. Do not fund E from F. No P2P. |

B and C are hop-symmetric: A→B→C and A→C→B use the same math.

---

## 2. Walkthrough map (use-case §1)

Emit / defer exactly as the step requires. Fees in the right column are
**hook** outcomes when you have already published (or refused to publish).

| Step | Actor | Your job | Hook / fee |
|---|---|---|---|
| 0 | D (or B / C) already-held | Keep published **0** / 30 bps | ALLOW 0.30% |
| 1 | A pool cash-out | **100** / REVERT / 0 | `WalletBlocked` |
| 1b | F pool cash-out | Registry write; do not call this `WalletBlocked` | `SanctionHit` L1 |
| 2 | A → B P2P | Emit **~65 / 800**; keeper publishes | — |
| 3 | B swap | Keep ~65 / 800 | FEE_OVERRIDE 8% |
| 4 | B → C P2P | Emit **~42 / 300** | — |
| 5 | C swap | Keep ~42 / 300 | FEE_OVERRIDE 3% |
| 6 | E or D 24h USD | You do not invent Floor C | `DailyAggregationBlocked` |
| 7 | D stale 5 min | Do not stamp a fake freshness to hide Floor B | FEE_OVERRIDE B mid 3% |
| 8 | Clean C → D ~10k, then D swap | No hop. Leave 0 so Floor D can fire | D mid 3% |
| 9 | Clean C → D $15k | No hop. Leave 0 | D large 8% |
| 10a | Clean C → E $500, E $500 | **Do not publish E** | A dust 3% |
| 10b | C → E $10k, E $1,000 | **Do not publish E** | A mid 8% |
| 10c | C → E $15k, E $15k | **Do not publish E** | `UnscoredMagnitudeBlocked` |
| 10d | E unbind feed | Still unpublished | `lastFx` / `PriceFallbackUsed` / `MagnitudeQuoteFailed` |
| 11–12 | Floors / escrow | Not yours | Officer / FeeEscrow |
| 13 | Opinion | File for the operator CO; never file with an authority | — |

---

## 3. Score formula (agent, not TypeScript)

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

## 4. Bands and fees you publish

| finalScore | riskLevel | hookOutput | recommendedFeeBps |
|---|---|---|---|
| 0–30 | STANDARD | ALLOW | **30** (pool 0.30%) |
| 31–70, hop 1 | ELEVATED | FEE_OVERRIDE | **800** (8%; pool keeps ~30, rest → FeeEscrow) |
| 31–70, hop 2 | ELEVATED | FEE_OVERRIDE | **300** (3%) |
| 71–100 | BLOCK | REVERT | **0** |

If hop is null and score is mid-band without a hop fee, use 300 unless facts
justify 800. REVERT always 0 bps.

If the keeper omitted a mid-band fee, the hook still maps 31–54 → 3% and
55–70 → 8%. Prefer publishing the hop fee yourself.

You do **not** execute FeeEscrow. The hook deposits the differential on
FEE_OVERRIDE from the fee you published.

---

## 5. What the hook decides without you

Do not overwrite these with a COA score:

| Floor | Who | Agent |
|---|---|---|
| **A** | Never-written row (E): this-swap USD 3% / 8% / REVERT. Same cuts on a never-scored **LP add**; >20% of pool can lift 3%→8% or mid→REVERT | Do not publish E |
| **B** | Stale `updatedAt` (demo 5 min). Published LP 0–30 does **not** arm Floor B on mint | Tick may stamp the same score; you do not invent staleness friction |
| **C** | 24h USD aggregation REVERT (swaps). LP uses `_lpDaily`, not swap C | Hook-local |
| **D** | Significant inbound vs published 0 (deferred keeper). Also bag-vs-swap on unpublished E | Leave D unpublished after tainted P2P until catch-up |

Sanctions list at LP / swap (`SanctionHit`) is Layer 1. A is score-100 exploit,
not a list hit. F is the live SDN subject — expect a registry write and
`SanctionHit`, not `WalletBlocked`.

LP (use-case header, not the Anvil click-path):

- Listed or published 71–100 → cannot add (`SanctionHit` / `WalletBlocked`).
- Published 31–70 → 3% / 8% full override on the mint (by score, not USD).
- Never-scored add → Floor A/C/D. On an **empty pool** the mint is ~100%
  impact; 8% `take` reverts if the manager holds nothing. An operator may
  ask you to publish **0–30** on that untrusted LP caller so the seed can
  land. That write is a **seed exception**, not a finding that the router is
  a clean trader. See `uhi10-sepolia`.
- Blocked remove: principal + fees sit in FeeEscrow 48h (not your release).

---

## 6. Subject you evaluate

`hookData` is ignored. Trusted router → originator field. Untrusted contract
→ **that contract is the subject**. Do not score PoolManager, hook, satellite,
oracle, or the token contracts.

---

## 7. Checklist before you emit JSON

1. A and `exploitConfirmed` → 100, not OFAC, unless `subjectListed`.
2. F / `ofacSubject` / live SDN match → registry write; swap is `SanctionHit` at L1.
3. E / `neverScored` → you should not be scoring; if asked, do not publish.
4. Hop present → apply `100 × 0.65^hops`, then add event/sanction facts.
5. 1-hop + a single FEE_OVERRIDE swap → still ≤ 70.
6. `recommendedFeeBps` matches hop band (800 / 300 / 30 / 0).
7. Floors A–D (including LP A/C) are not your score.
8. Walkthrough step matches §2 (defer D; never write E; no hop on clean C→D/E).
9. Sepolia or unknown EOA → `uhi10-sepolia`; treat as E until a keeper writes.
10. Opinion sources: venues and corpus ids — **never** this skill’s filename.

If any item is unclear, call `consult_skill` again with `uhi10-use-case`,
`uhi10-sepolia`, or `fact-scoring` / `task-swap-decision`.
