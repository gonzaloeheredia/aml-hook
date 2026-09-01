# AML (Anti-Money Laundering) Hook · Frontend demo

Institutional six-stage demo of the AML Hook use case: **exploit `WalletBlocked` (Wallet A, score 100, not listed)**, **N-hop decay**, **oracle-latency / inflow (Wallet D)**, **never-scored USD bands (Wallet E, funded by C)**, and ternary **ALLOW / FEE_OVERRIDE / REVERT**. Named-address OFAC (Office of Foreign Assets Control) (`SanctionHit`) is hook Layer 1 (whitepaper). It is not a demo wallet. Newsreader + Inter, ink/cream surfaces, Uniswap logo kept. Dark is the default. The round control in the navbar toggles light.

Scores for A–D come from the API in-memory ledger (hop + band). The COA may draft Opinion in the background; it does not publish `ComplianceOracle` for those IDs. Wallet E leaves the simulator: faucet + **Open pool on Uniswap**. Opinion is `GET /compliance` (Claude when the API has a key). This UI makes no OpenSanctions, Etherscan, or GoPlus HTTP calls.
The UI sends requests only to the API at `NEXT_PUBLIC_API_URL` (default `http://localhost:4000`). A–D work if Sepolia RPC is down. Hosted: set `NEXT_PUBLIC_API_URL` to that API.

## Guided stages

On-screen titles (serif, same size on every stage): **Swap**, **Hook execution**, **Fee summary**, **AML stats**, **AML Analysis**, **Event**. The rail under the title is Swap · Hook · Fees · Stats · Opinion · Event.

| # | Rail | Title | Purpose |
|---|---|---|---|
| 1 | **Swap** | Swap | Connect wallet + `Get started` |
| 2 | **Hook** | Hook execution | Hook lifecycle (`beforeSwap`) |
| 3 | **Fees** | Fee summary | Pool standard fee + risk differential (`FeeSummary` only) |
| 4 | **Stats** | AML stats | Score gauge, report overview, detection data |
| 5 | **Opinion** | AML Analysis | Legal / technical opinion (A–E) from **oracle COA** via `/compliance` |
| 6 | **Event** | Event | A–D: API demo trail. E: on-chain `SwapObserved` |

**Get started** opens Hook. After the graph finishes, A–D unlock Fees; the floating control (and the rail) move to the next module. No automatic jump between analysis stages.

All stages accept a click on the left half of the screen for previous and the right half for next. Wheel scrolls content first and changes stage at scroll edges. Desktop also shows chevrons on the sides of the current module. The stage rail jumps to any unlocked step.

Forward (next module, enters from the right) uses a slow slide (2s; Opinion 6s). Back (previous module) uses a short slide (~0.4s).

On the first visit from Opinion → Event, Event stays locked for the Opinion slide plus **15s** so the file can be scrolled. The demo then advances. Wheel does not skip this wait. On revisit, Event is already unlocked.

**Restart data** (fixed control, bottom-right) calls `POST /reset`, clears local swap/event state, and returns to Swap.

**Event** shows the use-case after-swap record (API `source=demo` for A–D; chain logs for E):

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

**Wallet E (unknown)** is a new Sepolia EOA. Faucet `POST /demo/mint` `{ address }` then swap on the live pool. A–D P2P does not fund that EOA. The first fill while `updatedAt == 0` uses never-scored floors (3% / 8% / revert by size). After the keeper writes 0–30, later swaps use that row.

N-hop formula (A–D store + skill `uhi10-use-case`): `score = 100 × 0.65^hops` (`exposed_proportion` is 1.0 in this demo).
`POST /transfers` and `POST /swaps` on A–D return as soon as the store updates. Closer hop wins if a wallet is contaminated more than once.

## Run locally

```bash
# Terminal 1: API (A–D are in-memory; Sepolia env is only for Wallet E / health)
cd apps/api
npm install
npm run dev

# Terminal 2: UI
cd apps/frontend
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). API: [http://localhost:4000/health](http://localhost:4000/health). A–D do not need `chain.ok`.

## Demo walkthrough

1. Connect **Wallet D** → swap → ALLOW 0.30% (published score 0)
2. Connect **Wallet A** → swap → `WalletBlocked` (score 100, not listed)
3. Open **MetaMask Simulator** → optional **Mint 1,000 USDC** / **Mint 1 ETH** on the open account → Send USDC **A→B**, then **B→C**
4. Swap with **B** → FEE_OVERRIDE 8%; with **C** → FEE_OVERRIDE 3%
5. On **D**, swap $1,000, then **Advance 5 min** with no keeper write → 3% on a $1,000 swap (Floor B mid). An operating keeper stamps `updatedAt` every **3 minutes** without calling the agent. Floor B only arms at **5 minutes** if that stamp is late.
6. Restart. Send **10,000** C→D (C still clean) → D swap → 3% (inflow, no hop). Restart. Send **15,000** C→D → D swap → 8%
7. Wallet **E**: faucet `{ address }` → swap on Sepolia (first fill may still be Floor A; the keeper then publishes 0–30)
8. From **Fees**, click forward → **AML stats** → **Opinion** → **Event**

## Data source

Static case templates live in `src/data/cases.ts`. A–D ledger and compliance flow through `src/lib/api.ts` → `apps/api` store. Wallet E uses the faucet + Uniswap; Event can read Sepolia `SwapObserved`. Keys stay on the API. The browser never sees keeper or attestor keys.

## Related docs (repo root)

- `docs/Whitepaper.md`: product + AccessManager roles (§3.5)
- `docs/Use_Case.md`: A–E demo narrative. Sepolia stack: `docs/Whitepaper.md` (Stack)
- `contracts/README.md`: Foundry layout (`src/contracts/…`, `script/Deploy.sol`, `CreatePool.s.sol`)
- `apps/api/README.md`: A–D memory ledger; E / faucet on Sepolia

This UI never communicates with a live MetaMask extension. **Connect** picks demo wallets A–E. The faucet only mints MockUSDC / MockWETH to an address via `POST /demo/mint`.

**Never-scored applies only until the first keeper write.** The faucet does not publish `ComplianceOracle`. The first swap on the Sepolia pool while `updatedAt == 0` is Floor A/C/D: 3% under $1,000, 8% from $1,000–$14,999 (or revert if the ticket is more than 20% of pool liquidity), revert at ≥ $15,000. After `_ORACLE_KEEPER` publishes 0–30 (`POST /oracle/E/after-swap` or the 3-minute tick), later swaps read that score.
