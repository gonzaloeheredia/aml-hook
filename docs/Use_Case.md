# AML Hook — Use case

This walkthrough is the product demo of the whitepaper. Every decision below is the same mapping `RiskPolicy.decide` applies on-chain (score bands plus floors A–D, including Floor C). The frontend talks to the API; the API calls `AmlHook.previewSwap` on the configured chain so quotes cannot drift from the hook.

Two environments:

| | Guided demo (this file) | Live pool |
| --- | --- | --- |
| Chain | Anvil `31337` (local default) | Ethereum Sepolia `11155111` |
| UI / API | Next.js + `apps/api` (MetaMask **simulator** — not the browser extension). Local: `deploy:local`. Hosted: `NEXT_PUBLIC_API_URL` → API with `ORACLE_CHAIN_ID=11155111` | Same UI/API: judge faucet is `POST /demo/mint` `{ address }` (not in the panel) + keeper/COA write this chain. SDK `getDeployment` is still 31337-only |
| Pool | `previewSwap` + `observeSwap` + FeeEscrow. `MockPoolManager` | Official Uniswap v4 PoolManager + seeded liquidity (app.uniswap.org). The demo swap card is still preview, not a live fill |
| Addresses | `contracts/deployments/31337.json` | [`Sepolia.md`](Sepolia.md) |

A judge who connects a **new** EOA to the Sepolia pool (app.uniswap.org) is Wallet E: no oracle row → Floor A/C/D. The judge faucet is API-only (`POST /demo/mint` `{ address }`): 10,000 MockUSDC + 1 MockWETH. It is not in the MetaMask panel and does not publish a score. Elevated fee or revert by size is intentional until `_ORACLE_KEEPER` writes a clean row. The first Sepolia mint used Uniswap's `PoolModifyLiquidityTest` as the subject (untrusted router); it needed a published 0–30 score before add, because a never-scored mint on an empty pool is 100% impact and the 8% `take` reverts.

The Compliance Officer Agent emits `finalScore` and `recommendedFeeBps` (Claude when `ANTHROPIC_API_KEY` is set; skill interpreter otherwise). N-hop math lives in skill `uhi10-use-case`. The keeper publishes that row to `ComplianceOracle`. `POST /transfers` and `POST /swaps` wait until the agent has written. The 3-minute keeper tick only stamps the last score. `beforeSwap` never calls the agent.

The pool is a Uniswap v4 RWA (Real World Asset) pool with AML Hook attached. Swaps go through `beforeSwap` and `afterSwap`. Peer-to-peer USDC transfers happen off-pool. Those transfers are what move hop risk. Pool swaps do not create hops; `afterSwap` still records activity / USD windows and can reevaluate the COA.

A wallet on the sanctions list, or with a published score of 71–100, cannot add liquidity (`SanctionHit` / `WalletBlocked`). Known 31–70 pays a 3%/8% risk fee on the mint. Never-scored adds reuse swap Floor A/C/D. On a blocked remove that wallet receives nothing in-tx: principal and fees sit in FeeEscrow 48h. Checkpoint 2 reads the list and the oracle — if nothing is confirmed the principal returns to the LP and the fee goes to LpCompensationVault; if a later oracle write confirms a sanction, recover books `LP_PRINCIPAL` vs `ILLICIT_RISK_FEE`. Pause still lets a **clean** LP mint and withdraw; it does not lift a list or high-score hit. This walkthrough is swap-only.

## 1. Sequence at a glance

Use this table as the map while running the demo. Each row points to the matching step in section 3.

| Step | Actor | Action | Score | Decision | Fee / error |
| --- | --- | --- | --- | --- | --- |
| 0 | D (or B / C) | Swap of already-held USDC | 0 | ALLOW | 0.30% |
| 1 | A | Pool cash-out | 100 | REVERT | `WalletBlocked` (`SCORE_REVERT_BAND`) |
| 2 | A → B | P2P (peer-to-peer) | — | Agent emits 65; keeper publishes | — |
| 3 | B | Swap | 65 | FEE_OVERRIDE | 8% |
| 4 | B → C | P2P | — | Agent emits 42; keeper publishes | — |
| 5 | C | Swap | 42 | FEE_OVERRIDE | 3% |
| 6 | E (or D) | $10,000 then $5,000 in 24h | — / 0 | REVERT (C) | `DailyAggregationBlocked` |
| 7 | D | Advance 5 min, $1,000 swap | 0 stale | FEE_OVERRIDE (B mid) | 3% |
| 8 | C → D ~10k (C clean), then D swap | P2P, no hop | 0 | FEE_OVERRIDE (D mid) | 3% |
| 9 | C → D $15k (C clean) | P2P, then any D swap | 0 | FEE_OVERRIDE (D large) | 8% |
| 10a | C → E $500, then E $500 swap | — | FEE_OVERRIDE (A dust) | 3% |
| 10b | C → E $10k, then E $1,000 | — | FEE_OVERRIDE (A mid) | 8% |
| 10c | C → E $15k, then E $15,000 | — | REVERT | `UnscoredMagnitudeBlocked` |
| 10d | E | `POST /demo/price-feed` `{ bound: false }` (after a prior quote) | — | FEE_OVERRIDE (last FX) | Same 3%/8% as with a live feed. Silent if `lastFx` &lt; 30 min; `PriceFallbackUsed` only after 30 min (cache until 24h). `MagnitudeQuoteFailed` if never quoted or `lastFx` &gt; 24h |
| 11 | — | Normative review of floors A–D (whitepaper §8.4) | — | Officer / governor | — |
| 12 | FEE_OVERRIDE paths | Escrow hold 24h / 48h | — | On-chain FeeEscrow | Differential |
| 13 | Operator | Opinion stage | — | COA (Compliance Officer Agent) file | — |

How to run it: from the repo root, `npm run deploy:local`, then start the API and the frontend. Without Anvil the API returns `503` `{ error: "deploy_local" }`. Connect A–E from the wallet picker, move USDC in the MetaMask panel, or mint more MockUSDC / MockWETH with **Mint 1,000 USDC** / **Mint 1 ETH** (also `POST /demo/mint` `{ walletId, token, amount }`). Use the size chips and **Advance 5 min** on the swap card, and swap. Unbind the price feed is API-only (`POST /demo/price-feed`). Local quotes use `MockUsdFeed` ($1 USDC, $1,000 ETH). Demo ETH is mintable MockWETH, not native gas. The API exposes the same Anvil ledger on `POST /transfers`, `POST /swaps`, `POST /demo/mint`, `POST /demo/elapse`, `POST /demo/price-feed`, and `GET /escrow`. A demo swap is `previewSwap` + `observeSwap` + a FeeEscrow deposit on FEE_OVERRIDE — not a live Uniswap `PoolManager` fill. The Event stage reads the API event trail (`GET /events`), not a PoolManager log.

Named-address OFAC (`SanctionHit` at Layer 1) is hook functionality, not a demo wallet. See whitepaper §3.3 / §8.6.

## 2. The five wallets

| Wallet | Role | Starting score |
| --- | --- | --- |
| **A** | Confirmed exploit. Not on OFAC. Agent score 100. Pool swaps hit `WalletBlocked`. P2P can still contaminate B/C/D. Do not fund E from A. | 100 |
| **B** | Starts clean. | 0 (published) |
| **C** | Starts clean. Funds E (unknown) and D (inflow). Same hop rules as B. | 0 (published) |
| **D** | Published score 0. Starts with 5,000 USDC. | 0 (published) |
| **E** | Unknown. Starts empty. Clean C deposits USDC (no hop). | — (never written) |

B and C are symmetric for hops. Any path A → B → C or A → C → B produces the same hop math. D is confirmed clean until new funds arrive or a latency floor fires. E is unknown until the agent publishes a score. The step-by-step outcome for each wallet is in section 3.

## 3. How the hook decides

Same order as the whitepaper (§3.3 / §8.4) and `RiskPolicy.decide`. Floor C (24h USD) sits in that mapping and can still REVERT.

| Score or condition | Decision | Fee |
| --- | --- | --- |
| 0–30, published and fresh, no floor | ALLOW | Pool 0.30% |
| 31–54 (keeper omitted fee) | FEE_OVERRIDE | 3% |
| 55–70 (keeper omitted fee) | FEE_OVERRIDE | 8% |
| 1-hop (~65) / 2-hop (~42) with keeper fee | FEE_OVERRIDE | 8% / 3% |
| 71–100 | REVERT | `WalletBlocked` |
| On the sanctions list | REVERT add / seize remove | `SanctionHit` on swap and LP add; LP remove escrows principal + fees 48h |
| Published 0, inbound USD under $1,000, score still older than the baseline | ALLOW (D dust) | Pool 0.30% |
| Published 0, inbound USD $1,000–$14,999, score still older than the baseline | FEE_OVERRIDE (D mid) | 3% |
| Published, inbound USD ≥ $15,000, score still older than the baseline | FEE_OVERRIDE (D large) | 8% |
| Score older than `stalenessThreshold` (demo 5 minutes), **0** swaps in this hour | FEE_OVERRIDE (B first) | 3% |
| Score older than `stalenessThreshold` **and** at least one swap in this hour, assessed USD under $1,000 | ALLOW (B dust) | Pool 0.30% |
| Same Floor B trigger, assessed USD $1,000–$14,999 | FEE_OVERRIDE (B mid) | 3% |
| Same Floor B trigger, assessed USD ≥ $15,000 | FEE_OVERRIDE (B large) | 8% (pool-impact extra does not raise this further) |
| Same Floor B trigger, assessed USD under $1,000, swap > 20% of the pool | FEE_OVERRIDE (B extra) | 3% |
| Prior 24h USD > 0 and prior + this swap ≥ $15,000 | REVERT (C) | `DailyAggregationBlocked` |
| Never written, this swap under $1,000 | FEE_OVERRIDE | 3% (8% if the swap takes more than 20% of the pool) |
| Never written, this swap $1,000–$14,999 | FEE_OVERRIDE | 8% (REVERT if the swap takes more than 20% of the pool) |
| Never written, this swap ≥ $15,000 | REVERT | `UnscoredMagnitudeBlocked` |
| Never written, current bag $1,000–$14,999 (swap may be smaller) | FEE_OVERRIDE (D on E) | 3% |
| Never written, current bag ≥ $15,000 (swap may be smaller) | FEE_OVERRIDE (D on E) | 8% |
| Never-scored **LP add** under $1,000 | FEE_OVERRIDE (LP Floor A) | 3% full override into FeeEscrow (8% if the mint is more than 20% of the pool) |
| Never-scored **LP add** $1,000–$14,999 | FEE_OVERRIDE (LP Floor A mid) | 8% (REVERT if the mint is more than 20% of the pool) |
| Never-scored **LP add** ≥ $15,000 | REVERT (LP Floor A) | `UnscoredMagnitudeBlocked` |
| Never-scored **LP adds** in 24h: prior + this add ≥ $15,000 | REVERT (LP Floor C) | `DailyAggregationBlocked` — `_lpDaily`, not swap C |
| Published LP score 0–30, even if stale | ALLOW mint | 0 extra (Floor B does not arm) |
| Published LP score 31–70 | FEE_OVERRIDE by score | 3% / 8% full override (not USD) |
| USD quote required, no live round, and no `lastFx` within 24h | REVERT | `MagnitudeQuoteFailed` |

N-hop score (agent applies skill `uhi10-use-case`; keeper publishes):

`score = 100 × 0.65^hops`

| Wallet | Hops from A | Score | Decision |
| --- | --- | --- | --- |
| A | 0 | 100 | REVERT |
| B or C after A | 1 | 65 | FEE_OVERRIDE 8% |
| B or C after a 1-hop peer | 2 | 42 | FEE_OVERRIDE 3% |
| D after keeper catch-up from A | 1 | 65 | FEE_OVERRIDE 8% |

A second inbound from a closer source replaces the farther hop. Clean-to-clean P2P does not contaminate. The agent emits a new score when the hop or facts change. The keeper writes that row when the ALLOW / FEE / REVERT tier or the 3% / 8% fee band changes, **or** on a 3-minute heartbeat (same score, new `updatedAt`, no agent call), **or** when the last write is at least as old as `stalenessThreshold` (5 minutes). The 3-minute stamp is shorter than Floor B so a healthy API does not look stale when the agent is not re-run. If the agent is down, the tick still republishes the last score. If both the agent and the tick are down, Floor B fires after 5 minutes. That freshness stamp stops a stable clean wallet from looking stale. Floor B still fires when the keeper is actually late (demo: **Advance 5 min** with no intervening write).

## 4. Walkthrough

Reference for executing the demo step by step. Anvil must already be running (`npm run deploy:local`). Use the frontend (Connect + MetaMask panel) or the API. Amounts match the Anvil A–E wallets (#1–#5). Extra MockUSDC / MockWETH: MetaMask **Mint 1,000 USDC** / **Mint 1 ETH** or `POST /demo/mint`. On the swap card: **Advance 5 min** (Floor B). Unbind the price feed is `POST /demo/price-feed` `{ bound: false }` (uses `lastFx` after a prior quote: silent under 30 minutes, `PriceFallbackUsed` until 24h after that; `MagnitudeQuoteFailed` only if that token was never quoted or the cache is older than 24h). Restart data reseeds A–E on-chain.

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
| Sanctions | Clear (not written to `SanctionRegistry`) |
| Score | 100 (officer / external exploit analysis) |
| Decision | REVERT |
| Error | `WalletBlocked` · `"SCORE_REVERT_BAND"` |
| Settlement | None. Funds stay in A. |

A can still send USDC off-pool to B or C. Do not send A → E. A listed address is a different hook path (`SanctionHit` at Layer 1) — whitepaper §3.3 / §8.6 — not a wallet in this walkthrough.

### Step 2 — A sends to B

In MetaMask, send USDC from A → B.

The agent evaluates the transfer (`uhi10-use-case` → 1 hop ≈ 65 / 8%). The API waits, then the keeper publishes that row on `ComplianceOracle`.

### Step 3 — B swaps (1 hop)

Connect B. Swap.

| Check | Result |
| --- | --- |
| Score | 65 |
| Decision | FEE_OVERRIDE |
| Fee | 8% (0.30% stays in the pool; the rest is the FeeEscrow differential) |

### Step 4 — B sends to C

Send USDC from B → C.

The agent evaluates the transfer (2 hops ≈ 42 / 3%). The API waits, then the keeper publishes that row.

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

### Step 7 — Mitigation B (stale score)

Stay on D (or any published-clean wallet that already swapped in this hour). Press **Advance 5 min**. Swap again.

| Check | Result |
| --- | --- |
| Score | 0, now older than 5 minutes (demo `stalenessThreshold`; the hook governor retunes this) |
| Ops in window | > 0 |
| Decision | FEE_OVERRIDE |
| Floor | `STALE_WITH_POOL_ACTIVITY` |
| Fee | 3% on a $1,000 swap (mid band). Under $1,000 passes. $15,000 or more → 8%. A swap that takes more than 20% of the pool hardens the band and stops at 8%. B never reverts. |

A stale score with **no** prior swap in the hour is also Floor B: **3%** on that first swap (8% if it takes more than 20% of the pool). Floor B fires when the keeper is actually late — the demo button advances the clock without a write. A healthy keeper stamps `updatedAt` again when the window ages, even if the score did not move.

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

E starts **empty**. In MetaMask, switch to **C** and send USDC to **E**. That is the only funding path in this walkthrough. A is the exploit origin — do not send A → E. E never takes a hop.

Floor A looks at **this swap**. Floor D looks at the **unpublished bag** C just sent (baseline 0 → the whole bag is inbound). The stricter fee wins. Use the size chips after C has funded E. Crossing $15,000 across several swaps in 24 hours is Floor C (`DailyAggregationBlocked`), not A.

| C → E then E swap | Decision | Fee / error |
| --- | --- | --- |
| C→E $500, E swaps $500 | FEE_OVERRIDE | 3% (A dust; bag under $1,000) |
| C→E $10,000, E swaps $1,000 | FEE_OVERRIDE | 8% (A mid; D mid 3% loses) |
| C→E $15,000, E swaps $500 | FEE_OVERRIDE | 8% (D large on the bag) |
| C→E $15,000, E swaps $10,000 then $5,000 | REVERT | `DailyAggregationBlocked` |
| C→E $15,000, E swaps $15,000 | REVERT | `UnscoredMagnitudeBlocked` |

Call `POST /demo/price-feed` `{ bound: false }` after E (or D) has already been quoted at least once (there is no Unbind control on the swap card):

| Check | Result |
| --- | --- |
| Decision | Same floor as with a live feed (A/D bands still in USD) |
| Event | None if `lastFx` is younger than 30 minutes (`FX_HOT_TTL`). After 30 minutes, a live miss uses the cache until 24 hours and emits `PriceFallbackUsed` (`fromCache`) |
| Error | None, unless that token has no `lastFx` or the cache is older than 24 hours → `MagnitudeQuoteFailed` |

Bind the feed again to refresh the live round. A published score of 0 (Wallet D) and an unknown wallet (Wallet E) are different rows. Restart between the C→E sizes so C's 50,000 USDC covers each act.

### Step 11 — Normative review of the four floors

The $1,000 cut is the FATF virtual-asset threshold (Updated Guidance for VASPs, 2021, note 37). The $15,000 cut is Recommendation 10's occasional-transaction CDD floor. Floor C's 24-hour window is a BSA CTR analogy, not a FATF figure. B and D never revert (ongoing CDD + proportionality / de-risking). The 20% pool extra applies to A (and hardens B up to 8% only); it is not applied to D. Full cites are in whitepaper §8.4.

Who retunes: the compliance officer proposes then confirms USD floors, floor fees, and the pool-impact cut (48 hours). The hook governor retunes windows and binds extra price feeds. USD quoting skips Chainlink when `lastFx` is younger than 30 minutes (`FX_HOT_TTL`); after that it uses one live round or the cache until 24 hours. Local Anvil uses `MockUsdFeed` ($1 USDC, $1,000 ETH). Live Deploy binds official Chainlink ETH/USD and USDC/USD.

### Step 12 — FeeEscrow (FEE_OVERRIDE only)

On B (3% or 8%), D floors (3% or 8%), and E (3% or 8%), the pool keeps 0.30%. Floor C is a REVERT, so it does not hit escrow. The extra slice is deposited on Anvil into `FeeEscrow`. Open **Fees**: the panel lists those rows. Publish a list hit or oracle score ≥ 71 on that wallet, then warp **48h** → **Checkpoint 2** (the contract reads the oracle/list — no keeper bool) → Warp **7d** → **Recover**. A clean **risk-fee** row goes to `LpCompensationVault`; close an epoch and claim from **Fees**. A clean **LP-principal** row returns to the LP wallet. Recovered illicit fees book ComplianceTreasury `ILLICIT_RISK_FEE`; recovered seized capital books `LP_PRINCIPAL`. The officer proposes then executes an allowlisted payout after 48 hours. The two destinations cannot be the same address. `GET /escrow`, `POST /escrow/:id/checkpoint2`, `POST /escrow/:id/recover`, `GET /compensation`, `POST /compensation/close-epoch`, `POST /compensation/claim`, `GET /treasury`, and `POST /treasury/propose` are the same path without the UI.

| Window | What happens | RiskFee | LpPrincipal |
| --- | --- | --- | --- |
| 0–24h | Optional review | Still in escrow | Still in escrow |
| 24–48h | Early release (refused if already illicit on-chain) | LpCompensationVault | LP wallet |
| At 48h, list or score ≥ 71 | Block, then recover | ComplianceTreasury `ILLICIT_RISK_FEE` | ComplianceTreasury `LP_PRINCIPAL` |
| At 48h, not illicit | Release | LpCompensationVault | LP wallet |
| Nobody resolved (and still not illicit) | Default release | LpCompensationVault | LP wallet |

Owner recovery waits at least 7 days and can go only to the compliance reserve. After the full delay (default 90 days) anyone may send an expired blocked row to that same reserve. `FeeRecovered` records destination, token, amount, wallet, and the swap fingerprint. The fee never returns to the pool. User swap output settles in the same block.

### Step 13 — Opinion / COA file

After a FEE_OVERRIDE or REVERT, open **Opinion**. That screen is the Compliance Officer Agent file for this swap (whitepaper §7). With `ANTHROPIC_API_KEY` in `apps/api/.env`, Claude drafts it against the git corpus (`search_regulations`) after `consult_skill` (`uhi10-use-case`) and after it has already published the score and fee to `ComplianceOracle`. Without a key, the skill interpreter fills the same schema. The COA screens OFAC SDN (ETH addresses) on every Opinion and writes `SanctionRegistry` on an exact match; the swap still reads the mapping. There are still no live Chainalysis / TRM HTTP feeds. Successful swaps also emit `SwapObserved`. Reverts do not keep that log. Index the error on the failed transaction.
