# Headless demo flows

This folder is **not** the Foundry suite. Solidity tests live in [`contracts/test/`](../contracts/test/).

Scripts here exercise the same API routes the frontend uses (`/swaps`, `/transfers`, `/compliance`) without opening a browser. A–D routes are in-memory (hop + `applyPoolSwap`). They do not need Anvil and they do not touch the Sepolia pool ([`docs/Sepolia.md`](../docs/Sepolia.md)). Wallet E is faucet + Uniswap, not these scripts.

Foundry Solidity tests (mirroring `contracts/src/`) live in [`contracts/test/`](../contracts/test/). See that folder's README for the layout.

## Prerequisites

```bash
cd apps/api
npm run dev
```

API default: `http://localhost:4000` (override with `API_BASE`). A–D do not need Anvil.

## Uniswap + MetaMask demo flow

```bash
# from repo root
node test/flow-uniswap-metamask.mjs
```

Risk is hop-based. Swap count does not drive the score. The store applies `score = 100 × 0.65^hops`. `POST /transfers` and `POST /swaps` return after the memory update:

| Event | Effect |
|---|---|
| 2–3 Uniswap swaps while clean (B/C) | Still green · score 0 · 0.30% |
| Wallet A pool swap | **WalletBlocked** (score 100; not OFAC (Office of Foreign Assets Control)-listed) |
| MetaMask **A → B** (or A → C) | Hop **1** · score ~65 · fee **8%** |
| MetaMask **B → C** (or C → B) after that | Hop **2** · score ~42 · fee **3%** |
| Extra B ↔ A after hop 1 | B stays hop **1** (closer hop wins) |
| Wallet D swap of already-held funds | Published score **0** · ALLOW · **0.30%** |
| E $10k then $5k in 24h | **DAILY_AGGREGATION** · **REVERT** |
| D after a swap + 301s | **STALE_WITH_POOL_ACTIVITY** · **3%** on a $1,000 swap (**8%** at $15,000) |
| MetaMask **C → D** ~10k (C still clean) then D swap | Score **0** · no hop · inflow **FEE_OVERRIDE 3%** |
| MetaMask **C → D** $15k (C still clean) | inflow **FEE_OVERRIDE 8%** |
| Wallet E | Hosted: faucet `{ address }` + Uniswap. Not this script |

The script runs clean multi-swaps, then A `WalletBlocked`, then A→B, then B→A (still hop 1), then B→C (hop 2). After that B is at 8% and C is at 3%.

Wallet D inflow path: exercise via API (`POST /transfers` C→D while C is clean, `POST /swaps` D) or the frontend walkthrough. See [`apps/api/README.md`](../apps/api/README.md).
