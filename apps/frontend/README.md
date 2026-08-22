# AML Hook · Frontend demo

Hackathon UI for **Uniswap Hook Incubator 10 (UHI10)**.  
Uniswap-styled demo of the AML Hook use case: **exploit cash-out detection**, **N-hop decay**, **oracle-latency / inflow (Wallet D)**, **never-scored USD bands (Wallet E)**, and ternary **ALLOW / FEE_OVERRIDE / REVERT**.

> Scores and sanctions checks are **simulated** from the N-hop ledger — no live OpenSanctions / Etherscan / GoPlus (or OFAC) API calls.  
> The UI talks to the in-memory API at `NEXT_PUBLIC_API_URL` (default `http://localhost:4000`).

## Guided stages

| # | Stage | Purpose |
|---|---|---|
| 1 | **Swap** | Uniswap entry point — connect wallet + `Get started` |
| 2 | **Hook** | Flow simulator for the hook lifecycle |
| 3 | **Fees** | Pool standard fee + FeeEscrow differential (FEE_OVERRIDE) · gas · **Sold (USDC)** / **Bought (ETH)** |
| 4 | **AML stats** | Score gauge, report overview, detection data |
| 5 | **Opinion** | Legal / technical opinion (A–E) from **oracle COA** via `/compliance` |
| 6 | **Event** | `afterSwap` pool-chain payload only |

**Navigation**

- **Auto:** Swap → Hook on simulate. Hook completion lands on Fees (hold; no auto jump to AML stats).
- **All stages:** upper half of the screen = previous, lower half = next (click or wheel). Wheel scrolls content first; stage change at scroll edges. Stage rail also works.
- **Opinion → Event:** click only, lower half, after scrolling to the **end** of Opinion (wheel does not advance).
- **Restart data** (navbar): calls `POST /reset`, clears local swap/event state, returns to Swap.

**Event** shows the use-case `afterSwap` record:

```
{ address, score, decision, fee, amount_usdc, hop_distance?, origin?, timestamp }
```

REVERT is `beforeSwap` only — no `afterSwap` emit for that attempt.

**Navbar:** Connect chip shows `A · 0x…` with a **green / yellow / red** border from live risk (clean · hop/latency/unknown FEE_OVERRIDE · REVERT exploit). Wallet D shows **Score 0** until contaminated; **Latency** while keeper-pending. Wallet E stays **Unknown**. P2P USDC transfers run from the MetaMask simulator panel.

### The five use-case wallets

1. **Wallet A (exploit)** — score 100 · `REVERT`
2. **Wallet B (clean)** — receives from A → ~65 / 8%; from tainted C → ~42 / 3%
3. **Wallet C (clean)** — receives from A → ~65 / 8%; from tainted B → ~42 / 3%
4. **Wallet D (score 0)** — 5,000 USDC published clean. Held funds → ALLOW 0.30%. 4th swap in the hour → 8% (C). Advance 2 min after a swap → 8% (B). Clean C→D ~10k → inflow 8% (no hop). Clean C→D $25k → revert
5. **Wallet E (unknown)** — no oracle row. Chips: $500 → 3%; $1,000 / $10,000 → 8%; $25,000 or window sum → revert. Unbind feed → revert

N-hop formula: `derived_score = origin_score × (0.65 ^ hops) × exposed_proportion`  
Closer hop wins if a wallet is contaminated more than once. Never-scored magnitude is **USD-8**, not native token units.

## Run locally

```bash
# Terminal 1 — API (required for live ledger)
cd apps/api
npm install
npm run dev

# Terminal 2 — UI
cd apps/frontend
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). API: [http://localhost:4000/health](http://localhost:4000/health).

## Demo walkthrough

1. Connect **Wallet D** → swap → ALLOW 0.30% (published score 0)
2. Connect **Wallet A** → swap → REVERT
3. Open **MetaMask Simulator** → Send USDC **A→B**, then **B→C**
4. Swap with **B** → FEE_OVERRIDE 8%; with **C** → FEE_OVERRIDE 3%
5. On **D**, swap $1,000 four times → 4th is 8% (activity window). **Advance 2 min** → 8% (stale + activity)
6. Restart. Send **10,000** C→D (C still clean) → D swap → 8% (inflow, no hop). Restart. Send **25,000** C→D → D swap → revert
7. Connect **Wallet E** → $500 / $1,000 / $10,000 / $25,000 → 3% / 8% / 8% / revert. **Unbind price feed** → revert
8. From **Fees**, advance → **AML stats** → **Opinion** → **Event**

## Data source

- Static case templates: `src/data/cases.ts`
- Live ledger / compliance: `src/lib/api.ts` → `apps/api`
- Offline fallback overlay: `src/lib/withHopOverlay.ts`

## Related docs (repo root)

- `docs/Whitepaper.md` — product + AccessManager roles (§3.5)
- `docs/Use_Case.md` — A–E demo narrative
- `contracts/README.md` — Foundry layout (`src/contracts/…`, `script/Deploy.sol`)
- `apps/api/README.md` — ledger + COA + on-chain `updateScore` (`_ORACLE_KEEPER`)

Optional local stack: from repo root run `npm run deploy:local` (Anvil + AccessManager-wired contracts), then restart the API so quotes can read on-chain scores.