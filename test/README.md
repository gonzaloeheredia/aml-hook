# Headless demo flows (not unit tests)

This folder is **not** the Foundry suite — Solidity tests live in [`contracts/test/`](../contracts/test/).

Scripts here exercise the same API routes the frontend uses (`/swaps`, `/transfers`, `/compliance`, `/escrow`) **without opening a browser**. Those routes hit Anvil: quotes are `previewSwap`, P2P is ERC-20 `transfer`, FEE_OVERRIDE deposits into `FeeEscrow`. Need Anvil + API (`npm run deploy:local`, then `apps/api`).

Foundry Solidity tests (mirroring `contracts/src/`) live in [`contracts/test/`](../contracts/test/) — see that folder's README for the layout.

## Prerequisites

```bash
# repo root
npm run deploy:local

cd apps/api
npm run dev
```

API default: `http://localhost:4000` (override with `API_BASE`). Without Anvil the API returns `503` `{ error: "deploy_local" }`.

## Uniswap + MetaMask demo flow

```bash
# from repo root
node test/flow-uniswap-metamask.mjs
```

**Risk is hop-based, not swap-count** (plus Wallet D/E latency, activity, and magnitude paths in the API/UI):

| Event | Effect |
|---|---|
| 2–3 Uniswap swaps while clean (B/C) | Still green · score 0 · 0.30% |
| MetaMask **A → B** (or A → C) | Hop **1** · score ~65 · fee **8%** |
| MetaMask **B → C** (or C → B) after that | Hop **2** · score ~42 · fee **3%** |
| Extra B ↔ A after hop 1 | B stays hop **1** (closer hop wins) |
| Wallet D swap of already-held funds | Published score **0** · ALLOW · **0.30%** |
| D 4th $1k in the hour | **ACTIVITY_WINDOW_CAP** · **8%** |
| D after a swap + 301s | **STALE_WITH_POOL_ACTIVITY** · **8%** |
| MetaMask **C → D** ~10k (C still clean) then D swap | Score **0** · no hop · inflow **FEE_OVERRIDE 8%** |
| MetaMask **C → D** $25k (C still clean) | **InflowMagnitudeBlocked** |
| Wallet E first swap (API or frontend) | USD < $1,000 → **3%**; $1,000–$24,999 → **8%**; ≥ $25,000 or window → **REVERT**; unbound feed → **MagnitudeQuoteFailed** |

Script steps: clean multi-swaps → A REVERT → A→B → B→A (still hop 1) → B→C (hop 2) → B @ 8% vs C @ 3%.  
Wallet D inflow path: exercise via API (`POST /transfers` C→D while C is clean, `POST /swaps` D) or the frontend walkthrough — see [`apps/api/README.md`](../apps/api/README.md).
