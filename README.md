# AML Hook

Compliance layer for **Uniswap v4** (UHI10): a hook that intercepts swaps in `beforeSwap` / `afterSwap` and returns a ternary decision from an off-chain risk score.

| Score | Output | Effect |
|---|---|---|
| 0–30 | **ALLOW** | Standard pool fee (0.30%) |
| 31–70 | **FEE_OVERRIDE** | Dynamic fee (`lpFeeOverride`, e.g. 3%–8%) |
| 71–100 | **REVERT** | Fail-closed (exploit / sanctions exposure) |

Product docs: [`docs/Whitepaper.txt`](docs/Whitepaper.txt), [`docs/AML-Hook_Use_of_Case.txt`](docs/AML-Hook_Use_of_Case.txt).

## Use case — Exploit detection, propagation & N-hop decay

An attacker drains an external protocol and tries to cash out stolen USDC into ETH in an RWA Uniswap v4 pool protected by AML Hook. Blocked at the pool, they move funds off-pool via P2P; the keeper traces contamination with **N-hop decay** and writes updated scores before the next swap.

**Formula:** `derived_score = origin_score × (0.65 ^ hops) × exposed_proportion`  
(with full exposure → `score ≈ 100 × 0.65^hops`). If a wallet is reached by more than one path, the **closer hop wins**.

| Wallet | Role | Live score |
|---|---|---|
| **A** | Exploit source | **100 → REVERT** |
| **B** | Starts **clean** (same rules as C) | A→B → **~65 / 8%**; tainted C→B → **~42 / 3%** |
| **C** | Starts **clean** (same rules as B) | A→C → **~65 / 8%**; tainted B→C → **~42 / 3%** |

### Demo walkthrough (path A → B → C)

Exercises all three hook outputs in one run (other paths like A→C or A→C→B are equally valid):

0. **C** swaps clean → **ALLOW** 0.30%
1. **A** attempts pool cash-out → **REVERT**
2. **A → B** P2P → oracle writes score **65**
3. **B** swaps → **FEE_OVERRIDE** 8%
4. **B → C** P2P → oracle writes score **42**
5. **C** swaps → **FEE_OVERRIDE** 3%

## Guided UI (6 stages)

The frontend walks the use case as a staged demo:

| # | Stage | What it shows |
|---|---|---|
| 1 | **Swap** | Uniswap-style swap widget (connect wallet here) |
| 2 | **Hook** | Flow simulator (`beforeSwap` / decision) |
| 3 | **Fees** | Fee / gas + settled volume (**Sold USDC** / **Bought ETH**) |
| 4 | **AML stats** | Score, report overview, detection data |
| 5 | **Opinion** | Legal / technical dictamen from the **oracle COA** (sections A–D) |
| 6 | **Event** | Pool-chain `afterSwap` payload (`SwapObserved`) |

**Navigation**

- **Auto:** Swap → Hook on simulate. After the hook run finishes, the UI lands on **Fees** (short hold; does not auto-advance to AML stats).
- **Mouse on every stage:** **upper half** = previous, **lower half** = next (click or wheel). Wheel scrolls tall pages first; stage change only at scroll edges. Stage rail clicks also work.
- **Opinion → Event:** wheel never advances; go to Event only with a **lower-half click after scrolling to the end** of the Opinion module.
- Progressive unlock: later stages unlock as you reach them (Hook after simulate, Fees/stats after the hook run, Opinion from stats, Event from Opinion).
- **Connect chip** shows `A · 0x…` (or B/C) with a **green / yellow / red** border from live risk (clean / hop FEE_OVERRIDE / exploit REVERT).
- **Restart data** (navbar): reseeds wallets A/B/C via `POST /reset` and returns the demo to Swap.

**Off-chain oracle (Compliance Officer Agent)**

- Spec + skills: [`agents/oracle-coa/`](agents/oracle-coa/) (see `INTEGRATION.md`)
- Runner: `backend/src/oracle/` (MOCK_MODE — no live LLM/vendor APIs yet)
- Consumes P2P transfers + `afterSwap` / `WalletBlocked` events → writes score **before the next swap**
- `beforeSwap` (simulated) only **reads** the cached oracle score
- Opinion UI is filled from the same oracle evaluation (`task-regulatory-report` mapping)

**Event payload** (use-case `afterSwap` emit written to the pool chain):

`{ address, score, decision, fee, amount_usdc, hop_distance?, origin?, timestamp }`

REVERT happens in `beforeSwap` — `afterSwap` never runs, so nothing is written for that swap.

## Architecture (three layers)

```
┌─────────────────────────────────────────────────────────────┐
│  1. Off-chain oracle COA (today, in backend)                │
│     agents/oracle-coa skills · fact-scoring · dictamen      │
│     Triggered by afterSwap + P2P · in-memory score store    │
└───────────────────────────┬─────────────────────────────────┘
                            │  score (future: signed write)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  2. Oracle contract (next)                                  │
│     On-chain score store the hook can read at swap time     │
└───────────────────────────┬─────────────────────────────────┘
                            │  score lookup in beforeSwap
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  3. AML Hook (Uniswap v4) — next                            │
│     ALLOW / FEE_OVERRIDE / REVERT + afterSwap events        │
└─────────────────────────────────────────────────────────────┘
```

Today the **backend** owns the demo ledger **and** the oracle COA mock; the **frontend** calls it for wallets, P2P, swaps, compliance/Opinion. Smart contracts are not in this repo yet.

## Run the demos

| Layer | Install & commands |
|---|---|
| Backend API (`:4000`) | [`backend/README.md`](backend/README.md) |
| Frontend UI (`:3000`) | [`frontend/README.md`](frontend/README.md) |

Run **both** for the live demo (`NEXT_PUBLIC_API_URL` defaults to `http://localhost:4000`).
