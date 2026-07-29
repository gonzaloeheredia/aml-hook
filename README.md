# AML Hook

Compliance layer for **Uniswap v4** (UHI10): a hook that intercepts swaps in `beforeSwap` / `afterSwap` and returns a ternary decision from an off-chain risk score —

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
2. **A → B** P2P → keeper writes score **65**
3. **B** swaps → **FEE_OVERRIDE** 8%
4. **B → C** P2P → keeper writes score **42**
5. **C** swaps → **FEE_OVERRIDE** 3%

## Architecture (three layers)

```
┌─────────────────────────────────────────────────────────────┐
│  1. Backend (today)                                         │
│     In-memory TypeScript API · ledger · N-hop scores        │
│     Simulated sanctions / oracle copy — no live vendor APIs │
└───────────────────────────┬─────────────────────────────────┘
                            │  writes scores (future)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  2. Oracle contract (next)                                  │
│     On-chain score store the hook can read at swap time     │
└───────────────────────────┬─────────────────────────────────┘
                            │  score lookup in beforeSwap
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  3. AML Hook (Uniswap v4)                                   │
│     ALLOW / FEE_OVERRIDE / REVERT + on-chain audit events   │
└─────────────────────────────────────────────────────────────┘
```

Today the **backend simulates** what the keeper + oracle will do later. The **frontend** demos the hook UX against that logic (still mostly local mock; API wiring comes next). Smart contracts are not in this repo yet.

## Run the demos

| Layer | Install & commands |
|---|---|
| Backend API (`:4000`) | [`backend/README.md`](backend/README.md) |
| Frontend UI (`:3000`) | [`frontend/README.md`](frontend/README.md) |
