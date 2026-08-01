# AML Hook

Compliance layer for **Uniswap v4** (UHI10): a hook that intercepts swaps in `beforeSwap` / `afterSwap` and returns a ternary decision from an off-chain risk score.

| Score | Output | Effect |
|---|---|---|
| 0–30 | **ALLOW** | Standard pool fee (0.30%) |
| 31–70 | **FEE_OVERRIDE** | Dynamic fee (`lpFeeOverride`, e.g. 3%–8%) |
| 71–100 | **REVERT** | Fail-closed (exploit / sanctions exposure) |

Product docs: [`docs/Whitepaper.txt`](docs/Whitepaper.txt), [`docs/AML-Hook_Use_Case.txt`](docs/AML-Hook_Use_Case.txt).

## Monorepo layout

```text
aml-hook/
├── apps/
│   ├── frontend/       # Next.js guided demo UI (:3000)
│   └── api/            # Fastify ledger + oracle COA + optional on-chain keeper (:4000)
├── packages/
│   └── sdk/            # ABIs + Anvil deployment addresses for the frontend
├── contracts/          # Foundry — AmlHook + L1/L2/L3 (+ MockPoolManager for local)
│   └── test/           # Forge unit tests (*.t.sol)
├── agents/oracle-coa/  # Off-chain Compliance Officer Agent skill specs
├── docs/
├── scripts/            # deploy-local, sync-deployment, WSL Anvil helpers
└── test/               # Headless HTTP demo flows (not Forge) — see note below
```

**`test/` vs `contracts/test/`:** same folder name, different jobs. Root [`test/`](test/) = Node scripts against the demo API. [`contracts/test/`](contracts/test/) = Foundry Solidity tests (`forge test`). Prefer reading the folder README before assuming “unit tests.”

## Mock vs real (current boundary)

| Piece | Status | Notes |
|---|---|---|
| **SanctionRegistry / ComplianceOracle / RiskPolicy / AmlHook** | **Real contracts** | Deployed on Anvil via `DeployAmlStack` |
| **PoolManager** | **Mock** locally | `MockPoolManager` — address stand-in; no live Uniswap swaps |
| **Keeper `updateScore`** | **Real tx** when env set | Else mock trail in `GET /oracle/publishes` |
| **Demo beforeSwap score** | **Hybrid** | Prefers on-chain `getRisk` → memory COA → hop formula |
| **API ledger (balances, P2P, swap settle)** | **Mock** | In-memory; resets on process restart |
| **Oracle COA skills / Opinion** | **Mock** | Deterministic TS; no live LLM / vendors |
| **External monitors (Forta, etc.)** | **Not wired** | Spec only; demo uses scripted A/B/C ledger |

Code comments in `apps/api` and `contracts/src` call out MOCK vs REAL at the entry points.

## Architecture — call path & contract layers

```text
User → Router → PoolManager
                       │
              beforeSwap │ afterSwap
                       ▼
                   AMLHook
          ┌────────────┼────────────┐
          ▼            ▼            ▼
   SanctionRegistry  ComplianceOracle  RiskPolicy
     (Layer 1)         (Layer 2)         (Layer 3, decision)
                          ▲
                          │ updateScore(wallet, score, hopDistance, origin, signature)
                          │
                    Oracle Keeper (off-chain)
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
     External exploit-event       ERC-20 P2P transfer
     monitors (Forta,             monitor (wallet-to-wallet)
     Hypernative, protocol feeds)
```

| Component | Role |
|---|---|
| **AMLHook** | Uniswap v4 hook — runs at `beforeSwap` / `afterSwap` |
| **SanctionRegistry** | Layer 1 — on-chain sanctions screen (fail-closed) |
| **ComplianceOracle** | Layer 2 — stores behavioral score written by the keeper |
| **RiskPolicy** | Layer 3 — maps score → ALLOW / FEE_OVERRIDE / REVERT |
| **Oracle Keeper** | Off-chain COA — monitors exploits + P2P, then `updateScore` |

**`apps/api`** is the Oracle Keeper for the demo: after each score it calls `ComplianceOracle.updateScore` (mock trail or real Anvil tx). **`apps/frontend`** drives the UI. Pool swaps in the UI are still settled in the API ledger until a real PoolManager is wired.

## Local on-chain stack (Anvil)

From the repo root (Foundry on PATH, or WSL Foundry on Windows):

```bash
npm run deploy:local
# → starts Anvil (detached), forge DeployAmlStack, syncs SDK + apps/api/.env.local

# restart API so it loads .env.local
npm run start -w aml-hook-api   # or npm run dev:api
```

What `deploy:local` does:

1. Anvil on `:8545` (WSL uses `setsid/nohup` so the process survives the shell)
2. Deploys **real** L1/L2/L3 + AmlHook (CREATE2 flags); **MockPoolManager** unless `POOL_MANAGER` is set
3. Deployer = Anvil account #0 = ComplianceOracle **keeper**
4. Writes `contracts/deployments/31337.json` → copies to `packages/sdk/deployments/`
5. Writes `apps/api/.env.local`:

```env
ORACLE_RPC_URL=http://127.0.0.1:8545
COMPLIANCE_ORACLE_ADDRESS=0x…
KEEPER_PRIVATE_KEY=0xac0974…   # Anvil #0
SCORE_SOURCE=onchain
```

Verify:

```bash
curl http://127.0.0.1:4000/health
# publisher.mode: "rpc", scoreSource: "onchain"

# after a transfer A→B
curl http://127.0.0.1:4000/oracle/publishes
# status: "submitted" + txHash

curl http://127.0.0.1:4000/wallets/B
# scoreSource: "onchain"
```

SDK for the frontend:

```ts
import { getDeployment, complianceOracleAbi, amlHookAbi } from "@aml-hook/sdk";
const d = getDeployment(31337);
```

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

0. **C** swaps clean → **ALLOW** 0.30%
1. **A** attempts pool cash-out → **REVERT**
2. **A → B** P2P → oracle writes score **65**
3. **B** swaps → **FEE_OVERRIDE** 8%
4. **B → C** P2P → oracle writes score **42**
5. **C** swaps → **FEE_OVERRIDE** 3%

## Guided UI (6 stages)

| # | Stage | What it shows |
|---|---|---|
| 1 | **Swap** | Uniswap-style swap widget (connect wallet here) |
| 2 | **Hook** | Flow simulator (`beforeSwap` / decision) |
| 3 | **Fees** | Fee / gas + settled volume (**Sold USDC** / **Bought ETH**) |
| 4 | **AML stats** | Score, report overview, detection data |
| 5 | **Opinion** | Legal / technical opinion from the **oracle COA** (sections A–D) |
| 6 | **Event** | Pool-chain `afterSwap` payload (`SwapObserved`) |

**Off-chain oracle (Compliance Officer Agent)**

- Spec + skills: [`agents/oracle-coa/`](agents/oracle-coa/) (see `INTEGRATION.md`)
- Runner: `apps/api/src/oracle/` (MOCK_MODE — no live LLM/vendor APIs yet)
- Consumes P2P transfers + `afterSwap` / `WalletBlocked` events → writes score **before the next swap**
- Opinion UI is filled from the same oracle evaluation

**Event payload** (use-case `afterSwap` emit):

`{ address, score, decision, fee, amount_usdc, hop_distance?, origin?, timestamp }`

REVERT happens in `beforeSwap` — `afterSwap` never runs for that attempt.

## Run the demos

From the repo root (npm workspaces):

```bash
npm install
npm run deploy:local   # optional — on-chain oracle + keeper
npm run dev:api        # :4000  (restart after deploy:local)
npm run dev:frontend   # :3000
```

| Layer | Path | Commands |
|---|---|---|
| API (`:4000`) | [`apps/api/`](apps/api/README.md) | `npm run dev:api` |
| Frontend (`:3000`) | [`apps/frontend/`](apps/frontend/README.md) | `npm run dev:frontend` |
| Contracts | [`contracts/`](contracts/README.md) | Foundry — `forge test` / `DeployAmlStack` |
| SDK | [`packages/sdk/`](packages/sdk/README.md) | ABIs + `deployments/31337.json` after deploy |
| Local chain | `npm run deploy:local` | Anvil + stack + sync env/SDK |
| Demo flows | [`test/`](test/README.md) | `node test/flow-uniswap-metamask.mjs` |

`NEXT_PUBLIC_API_URL` defaults to `http://localhost:4000`.

## Still pending (not done)

- Wire a **real Uniswap v4 PoolManager** + pool so swaps execute on-chain through AmlHook (today: MockPoolManager + API-simulated settlement)
- Live COA vendors / LLM (still deterministic mock)
- Broader e2e / Foundry coverage beyond the current unit tests
