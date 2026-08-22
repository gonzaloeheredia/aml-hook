# AML Hook — Use case

This walkthrough is the product demo of the whitepaper. Every decision below is the same mapping `RiskPolicy` + hook-local Mitigation C apply on-chain. The frontend talks to the API; the API calls `AmlHook.previewSwap` on Anvil so quotes cannot drift from the hook.

The pool is a Uniswap v4 RWA (Real World Asset) pool with AML Hook attached. Swaps go through `beforeSwap` and `afterSwap`. Peer-to-peer USDC transfers happen off-pool. Those transfers are what move risk. Pool swaps never raise a score.

A sanctioned wallet that tries to add or remove liquidity is reverted at the liquidity boundary. That path reads the sanctions list only. This walkthrough is swap-only.

## 1. Sequence at a glance

Use this table as the map while running the demo. Each row points to the matching step in section 3.

| Step | Actor | Action | Score | Decision | Fee / error |
| --- | --- | --- | --- | --- | --- |
| 0 | D (or B / C) | Swap of already-held USDC | 0 | ALLOW | 0.30% |
| 1 | A | Pool cash-out | 100 | REVERT | `WalletBlocked` |
| 2 | A → B | P2P (peer-to-peer) | — | Keeper writes 65 | — |
| 3 | B | Swap | 65 | FEE_OVERRIDE | 8% |
| 4 | B → C | P2P | — | Keeper writes 42 | — |
| 5 | C | Swap | 42 | FEE_OVERRIDE | 3% |
| 6 | D | 4th $1,000 in the hour | 0 | FEE_OVERRIDE (C) | 8% |
| 7 | D | Advance 5 min, swap | 0 stale | FEE_OVERRIDE (B) | 8% |
| 8 | C → D ~10k (C clean), then D swap | P2P, no hop | 0 | FEE_OVERRIDE (D relative) | 8% |
| 9 | C → D $25k (C clean) | P2P, then any D swap | 0 | REVERT | `InflowMagnitudeBlocked` |
| 10a | E | $500 | — | FEE_OVERRIDE | 3% |
| 10b | E | $1,000 | — | FEE_OVERRIDE | 8% |
| 10c | E | $25,000 or window sum | — | REVERT | `UnscoredMagnitudeBlocked` |
| 10d | E | Unbind price feed | — | REVERT | `MagnitudeQuoteFailed` |
| 11 | — | KYC-policy review of the $25,000 floor | — | Governor | — |
| 12 | FEE_OVERRIDE paths | Escrow hold 24h / 48h | — | On-chain FeeEscrow | Differential |
| 13 | Operator | Opinion stage | — | COA (Compliance Officer Agent) file | — |

How to run it: from the repo root, `npm run deploy:local`, then start the API and the frontend. Without Anvil the API returns `503` `{ error: "deploy_local" }`. Connect A–E from the wallet picker, move USDC in the MetaMask panel, use the size chips and the two swap-card controls, and swap. The API exposes the same Anvil ledger on `POST /transfers`, `POST /swaps`, `POST /demo/elapse`, `POST /demo/price-feed`, and `GET /escrow`. A demo swap is `previewSwap` + `observeSwap` + a FeeEscrow deposit on FEE_OVERRIDE — not a live Uniswap `PoolManager` fill.

## 2. The five wallets

| Wallet | Role | Starting score |
| --- | --- | --- |
| **A** | Exploit source. Drained an external protocol and tries to cash out USDC → ETH in the pool. | 100 |
| **B** | Starts clean. | 0 (published) |
| **C** | Starts clean. Same rules as B. | 0 (published) |
| **D** | Published score 0. Starts with 5,000 USDC. | 0 (published) |
| **E** | Unknown. The oracle has never written a row for this address. Starts with 40,000 USDC. | — (never written) |

B and C are symmetric. Any path A → B → C or A → C → B produces the same hop math. D is confirmed clean until new funds arrive or a latency floor fires. E is unknown until the keeper publishes a score. The step-by-step outcome for each wallet is in section 3.

## 3. How the hook decides

Same order as the whitepaper (§3.3 / §8.4) and `RiskPolicy.decide`, then hook-local C if the policy still said ALLOW.

| Score or condition | Decision | Fee |
| --- | --- | --- |
| 0–30, published and fresh, no floor | ALLOW | Pool 0.30% |
| 31–54 (keeper omitted fee) | FEE_OVERRIDE | 3% |
| 55–70 (keeper omitted fee) | FEE_OVERRIDE | 8% |
| 1-hop (~65) / 2-hop (~42) with keeper fee | FEE_OVERRIDE | 8% / 3% |
| 71–100 | REVERT | `WalletBlocked` |
| On the sanctions list | REVERT | `SanctionHit` |
| Published 0, inbound USD > 50% of current USD, under $25,000, score still older than the baseline | FEE_OVERRIDE (D relative · differential) | 8% |
| Published, inbound USD ≥ $25,000, score still older than the baseline | REVERT | `InflowMagnitudeBlocked` |
| Score older than `stalenessThreshold` (demo 5 minutes) **and** at least one swap in this hour | FEE_OVERRIDE (B) | 8% |
| Fourth swap after three completed ops in the hour (default; governor may retune) | FEE_OVERRIDE (C) | 8% |
| Never written, assessed USD under $1,000 | FEE_OVERRIDE | 3% |
| Never written, $1,000–$24,999 | FEE_OVERRIDE | 8% |
| Never written, this swap + 1-hour window ≥ $25,000 | REVERT | `UnscoredMagnitudeBlocked` |
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

### Step 1 — Exploit cash-out (A)

Connect Wallet A. Swap any size.

| Check | Result |
| --- | --- |
| Sanctions | Clear (list lag) |
| Score | 100 |
| Decision | REVERT |
| Error | `WalletBlocked` |
| Settlement | None. Funds stay in A. |

A can still send USDC off-pool.

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

### Step 6 — Mitigation C (D, fourth swap in the hour)

Default cap: 3 completed ops in a 1-hour window. The hook governor can retune both knobs (`setActivityWindow`). Restart if D already received from A. Connect D. Swap $1,000 three times. Each of those is ALLOW 0.30%.

The **fourth** $1,000 swap in the same hour:

| Check | Result |
| --- | --- |
| Score | 0, published |
| Ops in window | 3 (cap) |
| Decision | FEE_OVERRIDE |
| Floor | `ACTIVITY_WINDOW_CAP` |
| Fee | 8% |

### Step 7 — Mitigation B (stale score + pool activity)

Stay on D (or any published-clean wallet that already swapped in this hour). Press **Advance 5 min**. Swap again.

| Check | Result |
| --- | --- |
| Score | 0, now older than 5 minutes (demo `stalenessThreshold`; the hook governor retunes this) |
| Ops in window | > 0 |
| Decision | FEE_OVERRIDE |
| Floor | `STALE_WITH_POOL_ACTIVITY` |
| Fee | 8% |

A stale score with **no** swap in the hour stays ALLOW. The first swap of a new hour does not arm Floor B. Floor B fires when the keeper is actually late — the demo button advances the clock without a write. A healthy keeper stamps `updatedAt` again when the window ages, even if the score did not move.

### Step 8 — C sends to D (clean inbound, relative inflow)

Restart so C and D are back at baseline. C is still clean (50,000 USDC). Do **not** use A here: A→D is a hop.

In MetaMask, send **10,000** USDC from **C → D**.

Connect D. Swap $1,000.

| Check | Result |
| --- | --- |
| Oracle score | 0 (published, no hop) |
| Hop | — |
| Inflow | +$10,000 USD is 66% of D's current $15,000 USD bag (above 50%, under $25,000) |
| Decision | FEE_OVERRIDE |
| Floor | `INFLOW_HEURISTIC` |
| Fee | 8% differential (pool keeps 0.30%; rest → FeeEscrow) |

The 50% test is inbound USD over current USD, not native units. Medium-risk increment → differential fee. At or above $25,000 USD → revert. The hook does not name C as the source. B also works for this $10,000 path while it is still clean. B starts with 25,000, so use C for the $25,000 act.

### Step 9 — D absolute floor ($25,000 inbound)

Restart. Send **25,000** USDC from **C → D** (C still clean). Connect D. Any swap size:

| Check | Result |
| --- | --- |
| Inbound USD | 25,000 since baseline |
| Decision | REVERT |
| Error | `InflowMagnitudeBlocked` |

This is the same $25,000 revert floor as an unknown wallet. Already-held clean funds never count as inbound.

### Step 10 — Unknown wallet E

Connect Wallet E. The oracle has no row. Assessed USD = this swap + USD already recorded in the hour. Use the size chips.

| Amount | Decision | Fee / error |
| --- | --- | --- |
| $500 | FEE_OVERRIDE | 3% |
| $1,000 | FEE_OVERRIDE | 8% |
| $10,000 | FEE_OVERRIDE | 8% (single swap) |
| Two $10,000 then a third that crosses $25,000 in the hour | REVERT | `UnscoredMagnitudeBlocked` |
| $25,000 | REVERT | `UnscoredMagnitudeBlocked` |

Press **Unbind price feed**, then any E size (or a D path that needs a USD quote):

| Check | Result |
| --- | --- |
| Decision | REVERT |
| Error | `MagnitudeQuoteFailed` |

Bind the feed again to continue. A published score of 0 (Wallet D) and an unknown wallet (Wallet E) are different rows. E never takes a hop, even from A: only the USD bands apply. Extra USDC for E can come from clean C if you want; it still does not write a score.

### Step 11 — $25,000 and the KYC-policy review

The $1,000 and $25,000 defaults follow the order of magnitude used in international AML for traditional banking (FATF Rec. 10 CDD at the lower band; enhanced scrutiny at the upper). For institutional DeFi the $25,000 revert floor must be reviewed together with the pool's KYC policy before production.

### Step 12 — FeeEscrow (FEE_OVERRIDE only)

On B (8%), C (3%), D floors (8%), and E (3% or 8%), the pool keeps 0.30%. The extra slice is deposited on Anvil into `FeeEscrow`. Open **Fees**: the panel lists those rows. Warp **48h** → **Checkpoint 2 · illicit** (Blocked) → Warp **7d** → **Recover → reserve**. The recovered amount goes to the compliance reserve, never the LP fund. The two destinations cannot be the same address. `GET /escrow`, `POST /escrow/:id/checkpoint2`, and `POST /escrow/:id/recover` are the same path without the UI.

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
