# Headless demo flows (not unit tests)

This folder is **not** the Foundry suite — Solidity tests live in [`contracts/test/`](../contracts/test/).

Scripts here exercise the same API routes the frontend uses (`/swaps`, `/transfers`, `/compliance`) **without opening a browser**. Swaps/transfers are **mocked in the API ledger**; with `npm run deploy:local` the keeper can still write **real** `updateScore` txs on Anvil.

Foundry Solidity tests (mirroring `contracts/src/`) live in [`contracts/test/`](../contracts/test/) — see that folder's README for the layout.

## Prerequisites

```bash
cd apps/api
npm run dev
```

API default: `http://localhost:4000` (override with `API_BASE`).

## Uniswap + MetaMask demo flow

```bash
# from repo root
node test/flow-uniswap-metamask.mjs
```

**Risk is hop-based, not swap-count** (plus Wallet D latency path in the API/UI):

| Event | Effect |
|---|---|
| 2–3 Uniswap swaps while clean (B/C) | Still green · score 0 · 0.30% |
| MetaMask **A → B** (or A → C) | Hop **1** · score ~65 · fee **8%** |
| MetaMask **B → C** (or C → B) after that | Hop **2** · score ~42 · fee **3%** |
| Extra B ↔ A after hop 1 | B stays hop **1** (closer hop wins) |
| MetaMask **A → D** then D swap (API) | Stale score **0** · inflow **FEE_OVERRIDE 8%** · catch-up ~**65** |
| Never-scored first swap (Wallet E, on-chain) | USD < $1,000 → **3%**; $1,000–$24,999 → **8%**; ≥ $25,000 → **REVERT**; no/stale Chainlink feed fail-closes |

Script steps: clean multi-swaps → A REVERT → A→B → B→A (still hop 1) → B→C (hop 2) → B @ 8% vs C @ 3%.  
Wallet D latency path: exercise via API (`POST /transfers` A→D, `POST /swaps` D) or the frontend walkthrough — see [`apps/api/README.md`](../apps/api/README.md).
