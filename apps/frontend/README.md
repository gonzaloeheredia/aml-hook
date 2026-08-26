# AML Hook · Frontend demo

Hackathon UI for **Uniswap Hook Incubator 10 (UHI10)**.  
Institutional six-stage demo of the AML Hook use case: **exploit `WalletBlocked` (Wallet A, score 100, not listed)**, **live OFAC SDN `SanctionHit` (Wallet F)**, **N-hop decay**, **oracle-latency / inflow (Wallet D)**, **never-scored USD bands (Wallet E, funded by C)**, and ternary **ALLOW / FEE_OVERRIDE / REVERT**. Newsreader + Inter, ink/cream surfaces, Uniswap logo kept. Dark is the default; the round control in the navbar toggles light.

> Scores come from Anvil via the API: the COA emits `finalScore` / fee, the
> keeper publishes `ComplianceOracle`, and `AmlHook.previewSwap` reads that
> row. Opinion is `GET /compliance` (Claude when the API has a key). Live
> OFAC SDN is screened by the API COA (writer → `SanctionRegistry`). No
> OpenSanctions / Etherscan / GoPlus HTTP from this UI.  
> The UI talks only to the API at `NEXT_PUBLIC_API_URL` (default `http://localhost:4000`). If Anvil is down the API returns `503` `{ error: "deploy_local" }` — there is no offline `withHopOverlay` policy.

## Guided stages

On-screen titles (serif, same size on every stage): **Swap**, **Hook execution**, **Fee summary**, **AML stats**, **AML Analysis**, **Event**. The rail under the title is Swap · Hook · Fees · Stats · Opinion · Event.

| # | Rail | Title | Purpose |
|---|---|---|---|
| 1 | **Swap** | Swap | Connect wallet + `Get started` |
| 2 | **Hook** | Hook execution | Hook lifecycle (`beforeSwap`) |
| 3 | **Fees** | Fee summary | Pool standard fee + FeeEscrow (FEE_OVERRIDE differential, LP-add risk fee, seized principal) · **EscrowPanel** (live Anvil rows, Warp 48h / 7d, checkpoint 2, recover by kind) · **Sold (USDC)** / **Bought (ETH)** |
| 4 | **Stats** | AML stats | Score gauge, report overview, detection data |
| 5 | **Opinion** | AML Analysis | Legal / technical opinion (A–F) from **oracle COA** via `/compliance` |
| 6 | **Event** | Event | `afterSwap` pool-chain payload only |

**Navigation**

- **Auto:** Swap → Hook on simulate. Hook wheels fill to each layer's `stepTimesSec`, then hold 3s and land on Fees. Fees holds 3s after its slide, then Stats. Opinion waits 15s (plus its slide) before Event.
- **All stages:** left half of the screen = previous, right half = next (click). Wheel scrolls content first; stage change at scroll edges. Desktop also shows chevrons on the sides of the current module. The stage rail jumps to any unlocked step.
- **Forward** (next module, enters from the right): slow slide (2s; Opinion 6s). **Back** (previous module): short (~0.4s).
- **Opinion → Event (first visit):** Event stays locked for the Opinion slide plus **15s** so the file can be scrolled, then the demo advances. Wheel does not skip this wait. Revisit: Event is already unlocked.
- **Restart data** (fixed control, bottom-right): calls `POST /reset`, clears local swap/event state, returns to Swap.

**Event** shows the use-case `afterSwap` record:

```
{ address, score, decision, fee, amount_usdc, hop_distance?, origin?, timestamp }
```

REVERT is `beforeSwap` only — no `afterSwap` emit for that attempt.

**Navbar:** Uniswap logo, **MetaMask Simulator** text link, theme switch, **Connect** pill. Connect always shows that label (title has the address when a wallet is connected). Wallet D shows **Score 0** until contaminated; **Latency** while keeper-pending. Wallet E stays **Unknown** and starts empty. P2P USDC transfers run from the MetaMask simulator panel.

### The six use-case wallets

1. **Wallet A (exploit)** — not listed · score 100 · `WalletBlocked`. P2P still contaminates B/C. Do not fund E from A.
2. **Wallet B (clean)** — receives from A → ~65 / 8%; from tainted C → ~42 / 3%
3. **Wallet C (clean)** — 50,000 USDC. Fund E (unknown, no hop) or D (inflow). Receive from A → ~65 / 8%; from tainted B → ~42 / 3%
4. **Wallet D (score 0)** — 5,000 USDC published clean. Held funds → ALLOW 0.30%. Advance 5 min after a $1,000 swap (no intervening write) → 3% (B mid). Clean C→D ~10k → inflow 3% (no hop). Clean C→D $15k → inflow 8%
5. **Wallet E (unknown)** — starts empty. Fund from clean **C** (no hop). C→E $500 → 3%; $10k then $1k swap → 8% (A mid); $15k bag + $500 swap → 8% (D); this swap $15k → revert. $10k then $5k → Floor C. Unbind feed after a quote → last FX (silent under 30 min; `PriceFallbackUsed` until 24h after that); `MagnitudeQuoteFailed` only if never quoted or cache > 24h
6. **Wallet F (OFAC SDN)** — live Treasury ETH identifier, not Anvil #6. No P2P. Pool swap → `SanctionHit`. Contrast with A (`WalletBlocked`).

N-hop formula (agent applies skill `uhi10-use-case`; keeper publishes): `score = 100 × 0.65^hops` (`exposed_proportion` is 1.0 in this demo).
The UI waits on `POST /transfers` and `POST /swaps` until that publish lands. Closer hop wins if a wallet is contaminated more than once. Never-scored magnitude is **USD-8**, not native token units. Local Anvil uses `MockUsdFeed` ($1 USDC, $1,000 ETH). A live Deploy binds official Chainlink ETH/USD and USDC/USD.

## Run locally

```bash
# repo root — required. Starts Anvil, deploys the stack, writes apps/api/.env.local
npm run deploy:local

# Terminal 1 — API (Anvil adapter)
cd apps/api
npm install
npm run dev

# Terminal 2 — UI
cd apps/frontend
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). API: [http://localhost:4000/health](http://localhost:4000/health) (`mode: "anvil"`, `chain.ok`). Restart the API after every `deploy:local`.

## Demo walkthrough

1. Connect **Wallet D** → swap → ALLOW 0.30% (published score 0)
2. Connect **Wallet A** → swap → `WalletBlocked` (score 100, not listed)
3. Connect **Wallet F** → swap → `SanctionHit` (live OFAC SDN; no P2P)
4. Open **MetaMask Simulator** → Send USDC **A→B**, then **B→C**
5. Swap with **B** → FEE_OVERRIDE 8%; with **C** → FEE_OVERRIDE 3%
6. On **D**, swap $1,000, then **Advance 5 min** with no keeper write → 3% on a $1,000 swap (Floor B mid). A healthy keeper stamps `updatedAt` every **3 minutes** without calling the agent; Floor B only arms at **5 minutes** if that stamp is late.
7. Restart. Send **10,000** C→D (C still clean) → D swap → 3% (inflow, no hop). Restart. Send **15,000** C→D → D swap → 8%
8. MetaMask **C → E** ($500 / $10k / $15k). Swap $500 after $500 bag → 3%; $1k after $10k bag → 8% (A mid); $500 after $15k bag → 8% (D). This swap $15k → revert. Then $10,000 + $5,000 → Floor C revert. **Unbind price feed** after a quote → last FX (silent under 30 min); `MagnitudeQuoteFailed` only if that token was never quoted or the cache is older than 24h
9. From **Fees**, advance → **AML stats** → **Opinion** → **Event**

## Data source

- Static case templates: `src/data/cases.ts`
- Live ledger / compliance / escrow: `src/lib/api.ts` → `apps/api` → Anvil
- Keys stay on the API. The browser never sees keeper or attestor keys.

## Related docs (repo root)

- `docs/Whitepaper.md` — product + AccessManager roles (§3.5)
- `docs/Use_Case.md` — A–F demo narrative
- `contracts/README.md` — Foundry layout (`src/contracts/…`, `script/Deploy.sol`)
- `apps/api/README.md` — Anvil adapter + COA + signed `updateScore`
