# Headless demo flows (not unit tests)

This folder is **not** the Foundry suite — Solidity tests live in [`contracts/test/`](../contracts/test/).

Scripts here exercise the same API routes the frontend uses (`/swaps`, `/transfers`, `/compliance`) **without opening a browser**. Swaps/transfers are **mocked in the API ledger**; with `npm run deploy:local` the keeper can still write **real** `updateScore` txs on Anvil.

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

**Risk is hop-based, not swap-count:**

| Event | Effect on B/C |
|---|---|
| 2–3 Uniswap swaps while clean | Still green · score 0 · 0.30% |
| MetaMask **A → B** (or A → C) | Hop **1** · score ~65 · fee **8%** |
| MetaMask **B → C** (or C → B) after that | Hop **2** · score ~42 · fee **3%** |
| Extra B ↔ A after hop 1 | B stays hop **1** (closer hop wins) |

Script steps: clean multi-swaps → A REVERT → A→B → B→A (still hop 1) → B→C (hop 2) → B @ 8% vs C @ 3%.
