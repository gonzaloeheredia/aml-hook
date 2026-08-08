# AML Hook

Compliance layer for **Uniswap v4** (UHI10). The hook intercepts swaps at `beforeSwap` / `afterSwap` and returns a ternary decision from a keeper-written risk score:

| Score | Output | Effect |
|---|---|---|
| 0–30 | **ALLOW** | Standard pool fee (0.30%) |
| 31–70 | **FEE_OVERRIDE** | Dynamic fee (`lpFeeOverride`, e.g. 3%–8%); differential slice in **FeeEscrow** for 48h (confiscation → LP compensation, never the pool) |
| 71–100 | **REVERT** | Fail-closed (exploit / sanctions exposure) |

The score is computed **off-chain** by the **Oracle Keeper** — a Compliance Officer Agent (COA): an AI AML analyst that will connect to external information sources (sanctions feeds, exploit monitors, on-chain graph signals) — and stored **on-chain** (`ComplianceOracle`). The hook only reads; it does not invent the score.

## Docs

| Doc | What it is |
|---|---|
| [`docs/Whitepaper.md`](docs/Whitepaper.md) | Product thesis, regulatory framing, why this exists |
| [`docs/Use_Case.md`](docs/Use_Case.md) | A/B/C/D exploit → N-hop + oracle-latency (Wallet D) scenario |
| [`docs/Instructivo_Contracts_Local.md`](docs/Instructivo_Contracts_Local.md) | Plain-language walkthrough of every contract + local Anvil |
| [`agents/oracle-coa/`](agents/oracle-coa/) | COA skill specs — AI Compliance Officer / AML analyst (Oracle Keeper) |

## Quick start

```bash
npm install

# optional — Anvil + real L1/L2/L3 + keeper env for the API
npm run deploy:local

npm run dev:api        # http://localhost:4000
npm run dev:frontend   # http://localhost:3000
```

`NEXT_PUBLIC_API_URL` defaults to `http://localhost:4000`.

After `deploy:local`, restart the API so it loads `apps/api/.env.local`. Check:

```bash
curl http://127.0.0.1:4000/health
# publisher.mode: "rpc" · scoreSource: "onchain"
```

| Layer | Path | Notes |
|---|---|---|
| Frontend | [`apps/frontend/`](apps/frontend/README.md) | Guided 6-stage demo UI |
| API / keeper | [`apps/api/`](apps/api/README.md) | In-memory ledger + COA + optional RPC publish |
| Contracts | [`contracts/`](contracts/README.md) | Foundry — `forge test` / `DeployAmlStack` |
| SDK | [`packages/sdk/`](packages/sdk/README.md) | ABIs + `getDeployment(31337)` |
| Demo flows | [`test/`](test/README.md) | Headless HTTP scripts (not Forge) |

**`test/` vs `contracts/test/`:** root `test/` = Node demo flows against the API. `contracts/test/` = Solidity unit tests (`forge test`).

## Architecture

`	ext
User → Router → PoolManager
                       │
              beforeSwap │ afterSwap
                       ▼
                   AMLHook
          ┌────────────┼────────────┐
          ▼            ▼            ▼
   SanctionRegistry  ComplianceOracle  RiskPolicy
     (Layer 1)         (Layer 2)         (Layer 3)
                          ▲
                          │ updateScore(...)
              Oracle Keeper / COA (off-chain)
         AI Compliance Officer · AML analyst
         → will connect to info sources / feeds
                          │
                          │ keeper-only resolutions
                          ▼
                     FeeEscrow
              (FEE_OVERRIDE differential fee, 48h)
              early / default → pool
              confiscate → LP compensation (never pool)
`

| Component | Role |
|---|---|
| **AmlHook** | Uniswap v4 hook — eforeSwap / fterSwap |
| **SanctionRegistry** | L1 — sanctions screen (fail-closed) |
| **ComplianceOracle** | L2 — score / hop / origin written by the keeper |
| **RiskPolicy** | L3 — score → ALLOW / FEE_OVERRIDE / REVERT (+ §3.8 latency floors) |
| **Oracle Keeper (COA)** | Off-chain AI Compliance Officer / AML analyst — scores wallets, updateScore, and drives FeeEscrow after COA memos (COA never writes on-chain; deferred publish for Wallet D) |
| **FeeEscrow** | Holds FEE_OVERRIDE differential fee for 48h (not swap output). Checkpoint 1 (≥24h: early release to pool. Checkpoint 2: confiscate to lpCompensationFund (LP compensation — never the pool) or release to pool. |

In this repo, **pps/api** is the demo keeper (deterministic mock of that COA; live LLM and vendor feeds are the production path). **pps/frontend** drives the UI. Pool swaps in the UI are still settled in the API ledger until a real PoolManager is wired; scores can already be published/read on Anvil.

## Mock vs real

| Piece | Status |
|---|---|
| SanctionRegistry · ComplianceOracle · RiskPolicy · AmlHook · FeeEscrow | **Real** contracts (FeeEscrow: Foundry suite; deploy wiring optional) |
| PoolManager | **Mock** locally (`MockPoolManager`) |
| Keeper `updateScore` | **Real tx** when RPC env is set; else mock trail |
| Demo beforeSwap score + fee | **Hybrid** — on-chain `getRisk` (score + `feeBps` from COA) → memory → hop |
| API ledger (balances, P2P, swap settle) | **Mock** (in-memory) |
| COA skills / Opinion | **Mock** (deterministic TS stand-in for the AI Compliance Officer; no live LLM/vendors yet) |
| External info sources (Forta, sanctions, graph feeds, etc.) | Spec / future wiring — COA will connect to these in production |

## Local on-chain stack

```bash
npm run deploy:local
```

1. Starts Anvil on `:8545` (WSL: detached so it survives the shell)
2. Deploys real L1/L2/L3 + AmlHook (CREATE2); MockPoolManager unless `POOL_MANAGER` is set
3. Deployer = Anvil account #0 = ComplianceOracle keeper
4. Writes `contracts/deployments/31337.json` → `packages/sdk/deployments/`
5. Writes `apps/api/.env.local` (`ORACLE_RPC_URL`, `COMPLIANCE_ORACLE_ADDRESS`, `KEEPER_PRIVATE_KEY`, `SCORE_SOURCE=onchain`)

Smoke after API restart:

```bash
# transfer A→B, then:
curl http://127.0.0.1:4000/oracle/publishes   # status: submitted + txHash
curl http://127.0.0.1:4000/wallets/B          # scoreSource: onchain
```

```ts
import { getDeployment, complianceOracleAbi, amlHookAbi } from "@aml-hook/sdk";
const d = getDeployment(31337);
```

## Demo use case (A → B → C → D)

Attacker **A** (score 100) is blocked at the pool, then moves USDC via P2P. The Oracle Keeper (COA / AI AML analyst) applies **N-hop decay** (`score ≈ 100 × 0.65^hops`; closer hop wins) and writes scores before the next swap — except on the **Wallet D** path, where `updateScore` is deferred so the demo can show §3.8 oracle-latency Mitigation D (inflow heuristic).

| Step | Action | Result |
|---|---|---|
| 0 | C swaps clean | ALLOW 0.30% |
| 1 | A tries pool cash-out | REVERT |
| 2 | A → B (P2P) | B ≈ 65 |
| 3 | B swaps | FEE_OVERRIDE 8% → differential fee into FeeEscrow |
| 4 | B → C (P2P) | C ≈ 42 |
| 5 | C swaps | FEE_OVERRIDE 3% → differential fee into FeeEscrow |
| 6 | A → D (P2P); keeper not yet published | D oracle score still **0** (pending) |
| 7 | D swaps under stale score | FEE_OVERRIDE **8%** (inflow heuristic) |
| 8 | Keeper catch-up | D ≈ **65** |

Latency floors elevate ALLOW → FEE_OVERRIDE only (never soften REVERT). When no keeper `feeBps` is present, the latency/inflow fee is **8%** (`LATENCY_FEE_BPS`).

Full narrative: [`docs/Use_Case.md`](docs/Use_Case.md) (§7 Wallet D).

## Guided UI (6 stages)

| # | Stage | Shows |
|---|---|---|
| 1 | Swap | Uniswap-style widget |
| 2 | Hook | beforeSwap / decision flow |
| 3 | Fees | Fee + settled Sold USDC / Bought ETH |
| 4 | AML stats | Score, report overview |
| 5 | Opinion | COA legal/technical opinion (FinCEN Who–How sections) |
| 6 | Event | `SwapObserved` / afterSwap payload |

REVERT is decided in `beforeSwap` — `afterSwap` never runs for that attempt.

## Repo layout

```text
aml-hook/
├── apps/frontend/      # Next.js demo (:3000)
├── apps/api/           # Ledger + COA + keeper (:4000)
├── packages/sdk/       # ABIs + Anvil addresses
├── contracts/          # Foundry stack (+ MockPoolManager)
├── agents/oracle-coa/  # COA skill specs
├── docs/               # Whitepaper, use case, instructivo
├── scripts/            # deploy-local, sync-deployment
└── test/               # Headless API demo flows
```

## Still pending

- Real Uniswap v4 PoolManager + pool (swaps through AmlHook on-chain)
- Live COA vendors / LLM
- Broader e2e beyond current Forge unit tests
