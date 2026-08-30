# AML (Anti-Money Laundering) Hook · Frontend demo

Institutional six-stage demo of the AML Hook use case: **exploit `WalletBlocked` (Wallet A, score 100, not listed)**, **N-hop decay**, **oracle-latency / inflow (Wallet D)**, **never-scored USD bands (Wallet E, funded by C)**, and ternary **ALLOW / FEE_OVERRIDE / REVERT**. Named-address OFAC (Office of Foreign Assets Control) (`SanctionHit`) is hook Layer 1 (whitepaper). It is not a demo wallet. Newsreader + Inter, ink/cream surfaces, Uniswap logo kept. Dark is the default. The round control in the navbar toggles light.

Scores come from the API (application programming interface) chain: the COA (Compliance Officer Agent) emits `finalScore` / fee, the keeper publishes `ComplianceOracle`, and `AmlHook.previewSwap` reads that row. Opinion is `GET /compliance` (Claude when the API has a key). Live OFAC SDN (Specially Designated Nationals) is screened by the API COA (writer → `SanctionRegistry`). This UI (user interface) makes no OpenSanctions, Etherscan, or GoPlus HTTP calls.
The UI sends requests only to the API at `NEXT_PUBLIC_API_URL` (default `http://localhost:4000`). Local Anvil mode returns `503` `{ error: "deploy_local" }` if the chain is down. There is no offline `withHopOverlay` policy. Hosted Sepolia: set `NEXT_PUBLIC_API_URL` to that API.

## Guided stages

On-screen titles (serif, same size on every stage): **Swap**, **Hook execution**, **Fee summary**, **AML stats**, **AML Analysis**, **Event**. The rail under the title is Swap · Hook · Fees · Stats · Opinion · Event.

| # | Rail | Title | Purpose |
|---|---|---|---|
| 1 | **Swap** | Swap | Connect wallet + `Get started` |
| 2 | **Hook** | Hook execution | Hook lifecycle (`beforeSwap`) |
| 3 | **Fees** | Fee summary | Pool standard fee + FeeEscrow · **EscrowPanel** (checkpoint 2 / recover) · **FundsPanel** (close epoch / LP (liquidity provider) claim / treasury propose-execute) · **Sold (USDC)** / **Bought (ETH)** |
| 4 | **Stats** | AML stats | Score gauge, report overview, detection data |
| 5 | **Opinion** | AML Analysis | Legal / technical opinion (A–E) from **oracle COA** via `/compliance` |
| 6 | **Event** | Event | `afterSwap` pool-chain payload only |

Auto navigation moves Swap → Hook on simulate. Hook stage indicators fill to each layer's `stepTimesSec`, then hold 3s and advance to Fees. Fees holds 3s after its slide, then Stats. Opinion waits 15s (plus its slide) before Event.

All stages accept a click on the left half of the screen for previous and the right half for next. Wheel scrolls content first and changes stage at scroll edges. Desktop also shows chevrons on the sides of the current module. The stage rail jumps to any unlocked step.

Forward (next module, enters from the right) uses a slow slide (2s; Opinion 6s). Back (previous module) uses a short slide (~0.4s).

On the first visit from Opinion → Event, Event stays locked for the Opinion slide plus **15s** so the file can be scrolled. The demo then advances. Wheel does not skip this wait. On revisit, Event is already unlocked.

**Restart data** (fixed control, bottom-right) calls `POST /reset`, clears local swap/event state, and returns to Swap.

**Event** shows the use-case `afterSwap` record:

```
{ address, score, decision, fee, amount_usdc, hop_distance?, origin?, timestamp }
```

REVERT is `beforeSwap` only. That attempt emits no `afterSwap`.

**Navbar:** Uniswap logo, **MetaMask Simulator** text link, theme switch, **Connect** pill. After connect the pill shows **Wallet A–E**. Click it to switch or disconnect. Wallet D shows **Score 0** until contaminated, and **Latency** while keeper-pending. Wallet E stays **Unknown** and starts empty. P2P (peer-to-peer) USDC transfers and **Mint 1,000 USDC** / **Mint 1 ETH** (MockUSDC / MockWETH) run from the MetaMask simulator panel under Tokens, to the open account only. The faucet is API-only (`POST /demo/mint` `{ address }` → 1,000 MockUSDC + 1 MockWETH). That path does not connect MetaMask and does not change A–E.

### The five use-case wallets

**Wallet A (exploit)** is not listed, score 100, `WalletBlocked`. P2P still contaminates B/C. Do not fund E from A.

**Wallet B (clean)** receives from A → ~65 / 8%; from tainted C → ~42 / 3%.

**Wallet C (clean)** holds 50,000 USDC. Fund E (unknown, no hop) or D (inflow). Receive from A → ~65 / 8%; from tainted B → ~42 / 3%.

**Wallet D (score 0)** starts with 5,000 USDC published clean. Held funds → ALLOW 0.30%. Advance 5 min after a $1,000 swap (no intervening write) → 3% (B mid). Clean C→D ~10k → inflow 3% (no hop). Clean C→D $15k → inflow 8%.

**Wallet E (unknown)** starts empty. Fund from clean **C** (no hop). C→E $500 → 3%; $10k then $1k swap → 8% (A mid); $15k bag + $500 swap → 8% (D); this swap $15k → revert. $10k then $5k → Floor C. Unbind the feed via `POST /demo/price-feed` after a quote → last FX (silent under 30 min; `PriceFallbackUsed` until 24h after that). `MagnitudeQuoteFailed` only if never quoted or cache > 24h.

N-hop formula (agent applies skill `uhi10-use-case`; keeper publishes): `score = 100 × 0.65^hops` (`exposed_proportion` is 1.0 in this demo).
The UI waits on `POST /transfers` and `POST /swaps` until that publish lands. Closer hop wins if a wallet is contaminated more than once. Never-scored magnitude is **USD-8**, not native token units. Local Anvil uses `MockUsdFeed` ($1 USDC, $1,000 ETH). A live Deploy binds official Chainlink ETH/USD and USDC/USD.

## Run locally

```bash
# repo root: required. Starts Anvil, deploys the stack, writes apps/api/.env.local
npm run deploy:local

# Terminal 1: API (local Anvil)
cd apps/api
npm install
npm run dev

# Terminal 2: UI
cd apps/frontend
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). API: [http://localhost:4000/health](http://localhost:4000/health) (`mode: "anvil"`, `chain.ok`). Restart the API after every `deploy:local`.

## Demo walkthrough

1. Connect **Wallet D** → swap → ALLOW 0.30% (published score 0)
2. Connect **Wallet A** → swap → `WalletBlocked` (score 100, not listed)
3. Open **MetaMask Simulator** → optional **Mint 1,000 USDC** / **Mint 1 ETH** on the open account → Send USDC **A→B**, then **B→C**
4. Swap with **B** → FEE_OVERRIDE 8%; with **C** → FEE_OVERRIDE 3%
5. On **D**, swap $1,000, then **Advance 5 min** with no keeper write → 3% on a $1,000 swap (Floor B mid). An operating keeper stamps `updatedAt` every **3 minutes** without calling the agent. Floor B only arms at **5 minutes** if that stamp is late.
6. Restart. Send **10,000** C→D (C still clean) → D swap → 3% (inflow, no hop). Restart. Send **15,000** C→D → D swap → 8%
7. MetaMask **C → E** ($500 / $10k / $15k). Swap $500 after $500 bag → 3%; $1k after $10k bag → 8% (A mid); $500 after $15k bag → 8% (D). This swap $15k → revert. Then $10,000 + $5,000 → Floor C revert. Unbind the feed with `POST /demo/price-feed` after a quote → last FX (silent under 30 min). `MagnitudeQuoteFailed` only if that token was never quoted or the cache is older than 24h
8. From **Fees**, advance → **AML stats** → **Opinion** → **Event**

## Data source

Static case templates live in `src/data/cases.ts`. Live ledger, compliance, and escrow data flow through `src/lib/api.ts` → `apps/api` → Anvil (local) or Sepolia (`ORACLE_CHAIN_ID=11155111`). Keys stay on the API. The browser never sees keeper or attestor keys.

## Related docs (repo root)

- `docs/Whitepaper.md`: product + AccessManager roles (§3.5)
- `docs/Use_Case.md`: A–E demo narrative. Sepolia pool: `docs/Sepolia.md`
- `contracts/README.md`: Foundry layout (`src/contracts/…`, `script/Deploy.sol`, `CreatePool.s.sol`)
- `apps/api/README.md`: COA + signed `updateScore` (Anvil or Sepolia)

This UI never communicates with a live MetaMask extension. **Connect** picks demo wallets A–E. The faucet only mints MockUSDC / MockWETH to an address via `POST /demo/mint`.

**Never-scored is intentional.** The faucet does not publish `ComplianceOracle`. Unless `_ORACLE_KEEPER` writes a clean score for that address, a swap on the Sepolia pool (app.uniswap.org) is Wallet E: Floor A/C/D. 3% under $1,000. 8% from $1,000–$14,999 (or revert if the ticket is more than 20% of pool liquidity). Revert at ≥ $15,000. That is the product design.
