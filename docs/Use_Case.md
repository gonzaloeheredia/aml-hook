# AML Hook — Use case

This walkthrough is the product demo of the whitepaper. Every decision below is the same mapping `RiskPolicy` + hook-local Mitigation C apply on-chain. The frontend talks to the API; the API calls `AmlHook.previewSwap` on Anvil so quotes cannot drift from the hook.

The pool is a Uniswap v4 RWA (Real World Asset) pool with AML Hook attached. Swaps go through `beforeSwap` and `afterSwap`. Peer-to-peer USDC transfers happen off-pool. Those transfers are what move risk. Pool swaps never raise a score.

A sanctioned wallet that tries to add or remove liquidity is reverted at the liquidity boundary. That path reads the sanctions list only. This walkthrough is swap-only.

## 1. Sequence at a glance

Use this table as the map while running the demo. Each row points to the matching step in section 3.

| Step | Actor | Action | Score | Decision | Fee / error |
| --- | --- | --- | --- | --- | --- |
| 0 | D (or B / C) | Swap of already-held USDC | 0 | ALLOW | 0.30% |
| 1 | A | Pool cash-out | 100 | REVERT | `SanctionHit` (OFAC) |
| 2 | A → B | P2P (peer-to-peer) | — | Keeper writes 65 | — |
| 3 | B | Swap | 65 | FEE_OVERRIDE | 8% |
| 4 | B → C | P2P | — | Keeper writes 42 | — |
| 5 | C | Swap | 42 | FEE_OVERRIDE | 3% |
| 6 | E (or D) | $10,000 then $5,000 in 24h | — / 0 | REVERT (C) | `DailyAggregationBlocked` |
| 7 | D | Advance 5 min, $1,000 swap | 0 stale | FEE_OVERRIDE (B mid) | 3% |
| 8 | C → D ~10k (C clean), then D swap | P2P, no hop | 0 | FEE_OVERRIDE (D mid) | 3% |
| 9 | C → D $15k (C clean) | P2P, then any D swap | 0 | FEE_OVERRIDE (D large) | 8% |
| 10a | C → E $500, then E $500 swap | — | FEE_OVERRIDE (A dust) | 3% |
| 10b | C → E $10k, then E $1,000 | — | FEE_OVERRIDE (D mid) | 3% |
| 10c | C → E $15k, then E $15,000 | — | REVERT | `UnscoredMagnitudeBlocked` |
| 10d | E | Unbind price feed | — | REVERT | `MagnitudeQuoteFailed` |
| 11 | — | Normative review of floors A–D (whitepaper §8.4) | — | Officer / governor | — |
| 12 | FEE_OVERRIDE paths | Escrow hold 24h / 48h | — | On-chain FeeEscrow | Differential |
| 13 | Operator | Opinion stage | — | COA (Compliance Officer Agent) file | — |

How to run it: from the repo root, `npm run deploy:local`, then start the API and the frontend. Without Anvil the API returns `503` `{ error: "deploy_local" }`. Connect A–E from the wallet picker, move USDC in the MetaMask panel, use the size chips and the two swap-card controls, and swap. Local quotes use `MockUsdFeed` ($1 USDC, $1,000 ETH). The API exposes the same Anvil ledger on `POST /transfers`, `POST /swaps`, `POST /demo/elapse`, `POST /demo/price-feed`, and `GET /escrow`. A demo swap is `previewSwap` + `observeSwap` + a FeeEscrow deposit on FEE_OVERRIDE — not a live Uniswap `PoolManager` fill.

## 2. The five wallets

| Wallet | Role | Starting score |
| --- | --- | --- |
| **A** | OFAC-listed exploit source. Pool swaps hit `SanctionHit`. P2P can still contaminate B/C/D. Do not fund E from A. | 100 |
| **B** | Starts clean. | 0 (published) |
| **C** | Starts clean. Funds E (unknown) and D (inflow). Same hop rules as B. | 0 (published) |
| **D** | Published score 0. Starts with 5,000 USDC. | 0 (published) |
| **E** | Unknown. Starts empty. Clean C deposits USDC (no hop). | — (never written) |

B and C are symmetric for hops. Any path A → B → C or A → C → B produces the same hop math. D is confirmed clean until new funds arrive or a latency floor fires. E is unknown until the keeper publishes a score. The step-by-step outcome for each wallet is in section 3.

## 3. How the hook decides

Same order as the whitepaper (§3.3 / §8.4) and `RiskPolicy.decide`, then hook-local Floor C (24h USD) which can still REVERT.

| Score or condition | Decision | Fee |
| --- | --- | --- |
| 0–30, published and fresh, no floor | ALLOW | Pool 0.30% |
| 31–54 (keeper omitted fee) | FEE_OVERRIDE | 3% |
| 55–70 (keeper omitted fee) | FEE_OVERRIDE | 8% |
| 1-hop (~65) / 2-hop (~42) with keeper fee | FEE_OVERRIDE | 8% / 3% |
| 71–100 | REVERT | `WalletBlocked` |
| On the sanctions list | REVERT | `SanctionHit` |
| Published 0, inbound USD under $1,000, score still older than the baseline | ALLOW (D dust) | Pool 0.30% |
| Published 0, inbound USD $1,000–$14,999, score still older than the baseline | FEE_OVERRIDE (D mid) | 3% |
| Published, inbound USD ≥ $15,000, score still older than the baseline | FEE_OVERRIDE (D large) | 8% |
| Score older than `stalenessThreshold` (demo 5 minutes) **and** at least one swap in this hour, assessed USD under $1,000 | ALLOW (B dust) | Pool 0.30% |
| Same Floor B trigger, assessed USD $1,000–$14,999 | FEE_OVERRIDE (B mid) | 3% |
| Same Floor B trigger, assessed USD ≥ $15,000 | FEE_OVERRIDE (B large) | 8% (pool-impact extra does not raise this further) |
| Same Floor B trigger, assessed USD under $1,000, swap > 20% of the pool | FEE_OVERRIDE (B extra) | 3% |
| Prior 24h USD > 0 and prior + this swap ≥ $15,000 | REVERT (C) | `DailyAggregationBlocked` |
| Never written, this swap under $1,000 | FEE_OVERRIDE | 3% (8% if the swap takes more than 20% of the pool) |
| Never written, this swap $1,000–$14,999 | FEE_OVERRIDE | 8% (REVERT if the swap takes more than 20% of the pool) |
| Never written, this swap ≥ $15,000 | REVERT | `UnscoredMagnitudeBlocked` |
| Never written, current bag $1,000–$14,999 (swap may be smaller) | FEE_OVERRIDE (D on E) | 3% |
| Never written, current bag ≥ $15,000 (swap may be smaller) | FEE_OVERRIDE (D on E) | 8% |
| USD quote required and feed missing / stale / bad | REVERT | `MagnitudeQuoteFailed` |

N-hop score:

`score = 100 × 0.65^hops`

| Wallet | Hops from A | Score | Decision |
| --- | --- | --- | --- |
| A | 0 | 100 | REVERT |
| B or C after A | 1 | 65 | FEE_OVERRIDE 8% |
| B or C after a 1-hop peer | 2 | 42 | FEE_OVERRIDE 3% |
| D after keeper catch-up from A | 1 | 65 | FEE_OVERRIDE 8% |

A second inbound from a closer source replaces the farther hop. Clean-to-clean P2P does not contaminate. The keeper writes when the ALLOW / FEE / REVERT tier or the 3% / 8% fee band changes, **or** when the last write is at least as old as `stalenessThreshold`. That freshness stamp stops a stable clean wallet from looking stale. Floor B still fires when the keeper is actually late (demo: **Advance 5 min** with no intervening write).

## 4. Walkthrough

Reference for executing the demo step by step. Anvil must already be running (`npm run deploy:local`). Use the frontend (Connect + MetaMask panel) or the API. Amounts match the Anvil A–E wallets (#1–#5). On the swap card: **Advance 5 min** (Floor B) and **Unbind price feed** (E / D absolute quote). Restart data reseeds A–E on-chain.

### Step 0 — Clean swap (D, or B / C)

Connect Wallet D. Swap $1,000 USDC → ETH.

| Check | Result |
| --- | --- |
| Sanctions | Clear |
| Score | 0, published |
| Decision | ALLOW |
| Fee | 0.30% |

D starts with 5,000 USDC and a published clean row. Size of already-held funds does not revert.

### Step 1 — OFAC cash-out (A)

Connect Wallet A. Swap any size.

| Check | Result |
| --- | --- |
| Sanctions | OFAC SDN (demo `SanctionRegistry`) |
| Score | 100 (not read after the hit) |
| Decision | REVERT |
| Error | `SanctionHit` |
| Settlement | None. Funds stay in A. |

A can still send USDC off-pool to B or C. Do not send A → E.

### Step 2 — A sends to B

In MetaMask, send USDC from A → B.

The keeper traces the transfer, writes score 65 on B (1 hop), and recommends 8%.

### Step 3 — B swaps (1 hop)

Connect B. Swap.

| Check | Result |
| --- | --- |
| Score | 65 |
| Decision | FEE_OVERRIDE |
| Fee | 8% (0.30% stays in the pool; the rest is the FeeEscrow differential) |

### Step 4 — B sends to C

Send USDC from B → C.

The keeper writes score 42 on C (2 hops) and recommends 3%.

C can also receive directly from A. That path is 1 hop (65 / 8%), and it wins over a later 2-hop inbound.

### Step 5 — C swaps (2 hops)

Connect C. Swap.

| Check | Result |
| --- | --- |
| Score | 42 |
| Decision | FEE_OVERRIDE |
| Fee | 3% |

Optional reverse: if B is still clean, tainted C → B is 2 hops (42 / 3%). The closer hop still wins.

### Step 6 — Floor C (24-hour USD aggregation)

C follows the BSA CTR idea: add up the wallet's pool dollars across the last 24 hours. While that running total stays under $15,000, C does nothing — A, B, or D decide each swap. The later swap that makes prior-24h + this swap cross $15,000 **reverts**. A first $15,000 ticket of the day is A/B/D, not C.

Restart. Send **15,000** USDC from clean **C → E**. Connect **E**. Swap **$10,000** (A mid + D large → 8%). Then swap **$5,000**:

| Check | Result |
| --- | --- |
| Prior 24h USD | 10,000 |
| This swap | 5,000 |
| Decision | REVERT |
| Error | `DailyAggregationBlocked` |

D works the same after two sized swaps that add to $15,000. The hook governor retunes the 24-hour window via `setDailyWindow`.

### Step 7 — Mitigation B (stale score + pool activity)

Stay on D (or any published-clean wallet that already swapped in this hour). Press **Advance 5 min**. Swap again.

| Check | Result |
| --- | --- |
| Score | 0, now older than 5 minutes (demo `stalenessThreshold`; the hook governor retunes this) |
| Ops in window | > 0 |
| Decision | FEE_OVERRIDE |
| Floor | `STALE_WITH_POOL_ACTIVITY` |
| Fee | 3% on a $1,000 swap (mid band). Under $1,000 passes. $15,000 or more → 8%. A swap that takes more than 20% of the pool hardens the band and stops at 8%. B never reverts. |

A stale score with **no** swap in the hour stays ALLOW. The first swap of a new hour does not arm Floor B. Floor B fires when the keeper is actually late — the demo button advances the clock without a write. A healthy keeper stamps `updatedAt` again when the window ages, even if the score did not move.

### Step 8 — C sends to D (clean inbound, mid band)

Restart so C and D are back at baseline. C is still clean (50,000 USDC). Do **not** use A here: A→D is a hop.

In MetaMask, send **10,000** USDC from **C → D**.

Connect D. Swap $1,000.

| Check | Result |
| --- | --- |
| Oracle score | 0 (published, no hop) |
| Hop | — |
| Inflow | +$10,000 USD (mid band) |
| Decision | FEE_OVERRIDE |
| Floor | `INFLOW_HEURISTIC` |
| Fee | 3% (pool keeps 0.30%; rest → FeeEscrow) |

Floor D bands inbound USD: under $1,000 passes; $1,000–$14,999 → 3%; $15,000 or more → 8%. D does not revert. The hook does not name C as the source. B also works for this $10,000 path while it is still clean. Use C for the $15,000 act so D's bag starts smaller.

### Step 9 — D large band ($15,000 inbound)

Restart. Send **15,000** USDC from **C → D** (C still clean). Connect D. Any swap size:

| Check | Result |
| --- | --- |
| Inbound USD | 15,000 since baseline |
| Decision | FEE_OVERRIDE |
| Floor | `INFLOW_HEURISTIC` |
| Fee | 8% |

Already-held clean funds never count as inbound. This is not a revert — only unknown-wallet Floor A blocks at $15,000.

### Step 10 — Unknown wallet E

E starts **empty**. In MetaMask, switch to **C** and send USDC to **E**. That is the only funding path in this walkthrough. A is OFAC-listed — do not send A → E. E never takes a hop.

Floor A looks at **this swap**. Floor D looks at the **unpublished bag** C just sent (baseline 0 → the whole bag is inbound). The stricter fee wins. Use the size chips after C has funded E. Crossing $15,000 across several swaps in 24 hours is Floor C (`DailyAggregationBlocked`), not A.

| C → E then E swap | Decision | Fee / error |
| --- | --- | --- |
| C→E $500, E swaps $500 | FEE_OVERRIDE | 3% (A dust; bag under $1,000) |
| C→E $10,000, E swaps $1,000 | FEE_OVERRIDE | 3% (D mid on the bag) |
| C→E $15,000, E swaps $500 | FEE_OVERRIDE | 8% (D large on the bag) |
| C→E $15,000, E swaps $10,000 then $5,000 | REVERT | `DailyAggregationBlocked` |
| C→E $15,000, E swaps $15,000 | REVERT | `UnscoredMagnitudeBlocked` |

Press **Unbind price feed**, then any E size (or a D path that needs a USD quote):

| Check | Result |
| --- | --- |
| Decision | REVERT |
| Error | `MagnitudeQuoteFailed` |

Bind the feed again to continue. A published score of 0 (Wallet D) and an unknown wallet (Wallet E) are different rows. Restart between the C→E sizes so C's 50,000 USDC covers each act.

### Step 11 — Normative review of the four floors

The $1,000 cut is the FATF virtual-asset threshold (Updated Guidance for VASPs, 2021, note 37). The $15,000 cut is Recommendation 10's occasional-transaction CDD floor. Floor C's 24-hour window is a BSA CTR analogy, not a FATF figure. B and D never revert (ongoing CDD + proportionality / de-risking). The 20% pool extra applies to A (and hardens B up to 8% only); it is not applied to D. Full cites are in whitepaper §8.4.

Who retunes: the compliance officer proposes then confirms USD floors, floor fees, and the pool-impact cut (48 hours). The hook governor retunes windows and binds extra price feeds. Local Anvil uses `MockUsdFeed` ($1 USDC, $1,000 ETH). Live Deploy binds official Chainlink ETH/USD and USDC/USD.

### Step 12 — FeeEscrow (FEE_OVERRIDE only)

On B (3% or 8%), D floors (3% or 8%), and E (3% or 8%), the pool keeps 0.30%. Floor C is a REVERT, so it does not hit escrow. The extra slice is deposited on Anvil into `FeeEscrow`. Open **Fees**: the panel lists those rows. Warp **48h** → **Checkpoint 2 · illicit** (Blocked) → Warp **7d** → **Recover → reserve**. The recovered amount goes to the compliance reserve, never the LP fund. The two destinations cannot be the same address. `GET /escrow`, `POST /escrow/:id/checkpoint2`, and `POST /escrow/:id/recover` are the same path without the UI.

| Window | What happens | Where the fee goes |
| --- | --- | --- |
| 0–24h | Optional review | Still in escrow |
| 24–48h | Early release | LP compensation fund |
| At 48h, illicit | Block, then recover | Compliance reserve (never the LP fund) |
| At 48h, not illicit | Release | LP compensation fund |
| Nobody resolved | Default release | LP compensation fund |

Owner recovery waits at least 7 days and can go only to the compliance reserve. After the full delay (default 90 days) anyone may send an expired blocked row to that same reserve. `FeeRecovered` records destination, token, amount, wallet, and the swap fingerprint. The fee never returns to the pool. User swap output settles in the same block.

### Step 13 — Opinion / COA file

After a FEE_OVERRIDE or REVERT, open **Opinion**. That screen is the Compliance Officer Agent file for this swap (deterministic mock in this repo). It is the suspicious-operation documentation the whitepaper describes. Successful swaps also emit `SwapObserved`. Reverts do not keep that log. Index the error on the failed transaction.
