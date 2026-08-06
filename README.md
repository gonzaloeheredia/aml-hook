# AML Hook

Compliance layer for **Uniswap v4** (UHI10). The hook intercepts swaps at `beforeSwap` / `afterSwap` and returns a ternary decision from a keeper-written risk score:

| Score | Output | Effect |
|---|---|---|
| 0–30 | **ALLOW** | Standard pool fee (0.30%) |
| 31–70 | **FEE_OVERRIDE** | Dynamic fee (`lpFeeOverride`, e.g. 3%–8%) |
| 71–100 | **REVERT** | Fail-closed (exploit / sanctions exposure) |

The score is computed **off-chain** (Oracle Keeper / COA) and stored **on-chain** (`ComplianceOracle`). The hook only reads; it does not invent the score.

## Docs

| Doc | What it is |
|---|---|
| [`docs/Whitepaper.txt`](docs/Whitepaper.txt) | Product thesis, regulatory framing, why this exists |
| [`docs/AML-Hook_Use_Case.txt`](docs/AML-Hook_Use_Case.txt) | A/B/C exploit → N-hop demo scenario |
| [`docs/Instructivo_Contracts_Local.md`](docs/Instructivo_Contracts_Local.md) | Plain-language walkthrough of every contract + local Anvil |
| [`agents/oracle-coa/`](agents/oracle-coa/) | Off-chain Compliance Officer Agent skill specs |

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

```text
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
                    Oracle Keeper (off-chain)
```

| Component | Role |
|---|---|
| **AmlHook** | Uniswap v4 hook — `beforeSwap` / `afterSwap` |
| **SanctionRegistry** | L1 — sanctions screen (fail-closed) |
| **ComplianceOracle** | L2 — score / hop / origin written by the keeper |
| **RiskPolicy** | L3 — score → ALLOW / FEE_OVERRIDE / REVERT |
| **Oracle Keeper** | Off-chain COA — then `updateScore` before the next swap |

In this repo, **`apps/api`** is the demo keeper. **`apps/frontend`** drives the UI. Pool swaps in the UI are still settled in the API ledger until a real PoolManager is wired; scores can already be published/read on Anvil.

## Mock vs real

| Piece | Status |
|---|---|
| SanctionRegistry · ComplianceOracle · RiskPolicy · AmlHook | **Real** contracts on Anvil |
| PoolManager | **Mock** locally (`MockPoolManager`) |
| Keeper `updateScore` | **Real tx** when RPC env is set; else mock trail |
| Demo beforeSwap score + fee | **Hybrid** — on-chain `getRisk` (score + `feeBps` from COA) → memory → hop |
| API ledger (balances, P2P, swap settle) | **Mock** (in-memory) |
| COA skills / Opinion | **Mock** (deterministic TS; no live LLM/vendors) |
| External monitors (Forta, etc.) | Spec only — not wired |

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

## Demo use case (A → B → C)

Attacker **A** (score 100) is blocked at the pool, then moves USDC via P2P. The keeper applies **N-hop decay** (`score ≈ 100 × 0.65^hops`; closer hop wins) and writes scores before the next swap.

| Step | Action | Result |
|---|---|---|
| 0 | C swaps clean | ALLOW 0.30% |
| 1 | A tries pool cash-out | REVERT |
| 2 | A → B (P2P) | B ≈ 65 |
| 3 | B swaps | FEE_OVERRIDE 8% |
| 4 | B → C (P2P) | C ≈ 42 |
| 5 | C swaps | FEE_OVERRIDE 3% |

Full narrative: [`docs/AML-Hook_Use_Case.txt`](docs/AML-Hook_Use_Case.txt).

## Guided UI (6 stages)

| # | Stage | Shows |
|---|---|---|
| 1 | Swap | Uniswap-style widget |
| 2 | Hook | beforeSwap / decision flow |
| 3 | Fees | Fee + settled Sold USDC / Bought ETH |
| 4 | AML stats | Score, report overview |
| 5 | Opinion | COA legal/technical opinion (A–D) |
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
