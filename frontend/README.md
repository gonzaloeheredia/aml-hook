# AML Hook · Frontend demo

Hackathon UI for **Uniswap Hook Incubator 10 (UHI10)**.  
Uniswap-styled demo of the AML Hook use case: **exploit cash-out detection**, **N-hop decay**, and ternary **ALLOW / FEE_OVERRIDE / REVERT**.

> Scores and sanctions checks are **simulated** from the N-hop ledger — no live OpenSanctions / Etherscan / GoPlus (or OFAC) API calls.  
> The UI talks to the in-memory backend at `NEXT_PUBLIC_API_URL` (default `http://localhost:4000`).

## Guided stages

| # | Stage | Purpose |
|---|---|---|
| 1 | **Swap** | Uniswap entry point — connect wallet + `Get started` |
| 2 | **Hook** | Flow simulator for the hook lifecycle |
| 3 | **Fees** | Pool fee, `lpFeeOverride`, gas · **Sold (USDC)** / **Bought (ETH)** |
| 4 | **AML stats** | Score gauge, report overview, detection data |
| 5 | **Opinion** | Legal / technical opinion (A–D) from **oracle COA** via `/compliance` |
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

**Navbar:** Connect chip shows `A · 0x…` with a **green / yellow / red** border from live risk (clean / FEE_OVERRIDE hop / REVERT exploit). No separate wallet tag. P2P USDC transfers run from the MetaMask simulator panel.

### The three use-case wallets

1. **Wallet A (exploit)** — score 100 · `REVERT`
2. **Wallet B (clean)** — same rules as C: A→B ≈ 65 / 8%; tainted C→B ≈ 42 / 3%
3. **Wallet C (clean)** — same rules as B: A→C ≈ 65 / 8%; tainted B→C ≈ 42 / 3%

N-hop formula: `derived_score = origin_score × (0.65 ^ hops) × exposed_proportion`  
Closer hop wins if a wallet is contaminated more than once.

## Run locally

```bash
# Terminal 1 — API (required for live ledger)
cd backend
npm install
npm run dev

# Terminal 2 — UI
cd frontend
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). Backend: [http://localhost:4000/health](http://localhost:4000/health).

## Demo walkthrough

1. Connect **Wallet C** → swap → ALLOW 0.30% (baseline)
2. Connect **Wallet A** → swap → REVERT
3. Open **MetaMask Simulator** → Send USDC **A→B**, then **B→C**
4. Swap with **B** → FEE_OVERRIDE 8%; with **C** → FEE_OVERRIDE 3%
5. From **Fees**, advance → **AML stats** → **Opinion** → **Event**

## Data source

- Static case templates: `src/data/cases.ts`
- Live ledger / compliance: `src/lib/api.ts` → backend
- Offline fallback overlay: `src/lib/withHopOverlay.ts`

## Related docs (repo root)

- `docs/Whitepaper.txt`
- `docs/AML-Hook_Use_Case.txt`
