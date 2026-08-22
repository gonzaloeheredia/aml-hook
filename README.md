# AML Hook

Uniswap v4 hook that evaluates the swap subject at execution and returns a ternary decision: **ALLOW**, **FEE_OVERRIDE**, or **REVERT**.

The hook does not compute risk on-chain. An off-chain keeper (Compliance Officer Agent) writes a score into `ComplianceOracle`. `beforeSwap` reads that row, applies sanctions and latency floors, and either lets the swap through, takes a risk differential into `FeeEscrow`, or reverts. Liquidity add and remove are a sanctions-only gate. They do not read the score.

Built for UHI10.

## Documentation

The product thesis and the executable scenario live in `docs/`. Read those before the contracts.

| Document | Contents |
| --- | --- |
| [`docs/Whitepaper.md`](docs/Whitepaper.md) | Problem, architecture, roles, FeeEscrow, latency floors, regulatory framing, and competitive map |
| [`docs/Use_Case.md`](docs/Use_Case.md) | Five-wallet run of the whitepaper: exploit, N-hop, D floors (B/C/inflow/$25k), E bands + window + feed, Opinion |

Supporting notes:

| Document | Contents |
| --- | --- |
| [`contracts/README.md`](contracts/README.md) | Foundry layout, call path, roles |
| [`apps/api/README.md`](apps/api/README.md) | Demo ledger and keeper |
| [`apps/frontend/README.md`](apps/frontend/README.md) | Guided UI |
| [`agents/oracle-coa/`](agents/oracle-coa/) | COA skill specs |

## Decision surface

| Condition | Output | Settlement |
| --- | --- | --- |
| Score 0–30, published and fresh | ALLOW | Pool fee 0.30% |
| Score 31–70 | FEE_OVERRIDE | Pool keeps 0.30%. Extra slice → FeeEscrow (48h). Clean exit → LP compensation fund. Confirmed illicit → compliance reserve |
| Score 71–100 | REVERT | No swap |
| Sanctions list | REVERT | No swap. Score is not read |
| Published 0 + inbound USD > 50% of current USD, under $25,000 | FEE_OVERRIDE 8% | Medium-risk increment · differential |
| Published + inbound USD ≥ $25,000, score still older than the baseline | REVERT | `InflowMagnitudeBlocked` |
| Score older than `stalenessThreshold` (default 5 minutes) and at least one prior swap in the hour | FEE_OVERRIDE 8% | Floor B. Governor retunes. A healthy keeper stamps `updatedAt` again when the window ages. |
| Fourth swap after three completed ops in the hour (default) | FEE_OVERRIDE 8% | Mitigation C — governor retunes window / cap |
| Never written, assessed USD &lt; $1,000 | FEE_OVERRIDE 3% | Unknown wallet (use-case wallet E) |
| Never written, $1,000–$24,999 | FEE_OVERRIDE 8% | Unknown wallet |
| Never written, ≥ $25,000 (this swap or the 1-hour window) | REVERT | `UnscoredMagnitudeBlocked` |
| Never written, no usable USD price | REVERT | `MagnitudeQuoteFailed` |

A published score of 0 is confirmed clean. An address with no oracle row is unknown. Those are different paths. Full thresholds and who may retune them: whitepaper §8.4. The A–E walkthrough: use case. Fee escrow destinations: §8.3.

N-hop score written by the keeper:

```
score = 100 × 0.65 ^ hops
```

Closer hop wins. Pool swaps never raise a score. Peer-to-peer transfers do.

## On-chain stack

```
User → trusted router → PoolManager → AmlHook
                                         ├─ AmlHookLogic        subject, L1–L3, USD quote
                                         ├─ AmlHookSettlement   differential → FeeEscrow
                                         ├─ SanctionRegistry    Layer 1
                                         ├─ ComplianceOracle    Layer 2  ← keeper + attestor
                                         └─ RiskPolicy          Layer 3  (pure)
```

| Contract | Responsibility |
| --- | --- |
| `AmlHook` | Uniswap callbacks only |
| `AmlHookLogic` | Resolve subject, sanctions, score, latency floors, Chainlink USD |
| `AmlHookSettlement` | Take the fee differential. Does not decide risk |
| `SanctionRegistry` | Static list. New hits are commit-reveal |
| `ComplianceOracle` | Stored score, hop, origin, fee, timestamp |
| `RiskPolicy` | Score + floors → decision. No external calls |
| `FeeEscrow` | 48h hold of the extra fee. Clean / early / default → LP compensation fund. Confirmed illicit → compliance reserve. Own access list |
| `AccessManager` | Shared authority for registry, oracle, and hook governor |

Subject resolution uses a trusted router (`IMsgSender.msgSender()`). Uniswap `hookData` is ignored. An untrusted initiator reverts before any layer runs.

Writes are split so a score keeper cannot move escrow, and an escrow keeper cannot publish scores. `updateScore` requires `_ORACLE_KEEPER` plus a distinct attestor signature over wallet, score, hop, origin, fee, timestamp, and chain id.

## Demo wallets

The frontend and API implement the use-case ledger.

| Wallet | Starting state | What to try |
| --- | --- | --- |
| A | Exploit, score 100 | Pool swap reverts. P2P can contaminate B, C, D |
| B | Clean, score 0 | Receive from A → ~65 / 8%. Receive from tainted C → ~42 / 3% |
| C | Clean, score 0 | Receive from A → ~65 / 8%. Receive from tainted B → ~42 / 3% |
| D | Published score 0, 5,000 USDC | Swap held funds → ALLOW. Clean C→D then swap → 8% inflow (no hop) |
| E | Never written, 40,000 USDC | $500 → 3%. $1,000 → 8%. $25,000 → revert |

## Quick start

```bash
npm install

# optional — Anvil, AccessManager-wired stack, keeper env for the API
npm run deploy:local

npm run dev:api        # http://localhost:4000
npm run dev:frontend   # http://localhost:3000
```

`NEXT_PUBLIC_API_URL` defaults to `http://localhost:4000`. After `deploy:local`, restart the API so it loads `apps/api/.env.local`.

```bash
curl http://127.0.0.1:4000/health
# publisher.mode: "rpc"  ·  scoreSource: "onchain"
```

| Package | Path | Role |
| --- | --- | --- |
| Contracts | [`contracts/`](contracts/README.md) | Foundry. `forge test` · `script/Deploy.sol` |
| API / keeper | [`apps/api/`](apps/api/README.md) | In-memory ledger + COA + optional RPC publish |
| Frontend | [`apps/frontend/`](apps/frontend/README.md) | Six-stage demo |
| SDK | [`packages/sdk/`](packages/sdk/README.md) | ABIs + `getDeployment(31337)` |
| Headless flows | [`test/`](test/README.md) | HTTP scripts against the API. Not Forge |

`test/` is Node against the API. `contracts/test/` is Solidity (`forge test`).

## What is real vs mocked

| Piece | Status |
| --- | --- |
| AccessManager, SanctionRegistry, ComplianceOracle, RiskPolicy, AmlHook, FeeEscrow | Deployed contracts |
| Liquidity sanctions gate | On-chain. Demo UI is still swap-only |
| PoolManager | Local `MockPoolManager` unless `POOL_MANAGER` is set |
| `updateScore` | Real tx when RPC env is set and the key holds `_ORACLE_KEEPER` |
| Demo balances, P2P, swap settlement | In-memory API ledger |
| COA opinion | Deterministic stand-in. No live LLM or vendor feeds |

## Local deploy

```bash
npm run deploy:local
```

1. Starts Anvil on `:8545`.
2. Deploys AccessManager, L1/L2/L3, AmlHook (CREATE2), and FeeEscrow. Uses `MockPoolManager` unless `POOL_MANAGER` is set.
3. Wires roles. Anvil account #0 is the default admin / keepers / governor. Production requires a distinct `ATTESTOR`, a Safe as `ADMIN` or `FEE_ESCROW_OWNER`, and a dedicated `COMPLIANCE_RESERVE` (never the LP fund). Floor B default is 5 minutes (`DEFAULT_STALENESS` / `MAX_SCORE_AGE`). Institutional pools may tighten to 120 seconds.
4. Writes `contracts/deployments/31337.json` and copies it into `packages/sdk/deployments/`.
5. Writes `apps/api/.env.local`.

```ts
import { getDeployment, complianceOracleAbi, amlHookAbi } from "@aml-hook/sdk";

const d = getDeployment(31337);
```

## Repository

```text
aml-hook/
├── docs/               Whitepaper and use case
├── contracts/          Foundry — src/contracts · interfaces · AccessManager deploy
├── apps/api/           Ledger, COA, keeper
├── apps/frontend/      Next.js demo
├── packages/sdk/       ABIs and Anvil addresses
├── agents/oracle-coa/  COA skill specs
├── scripts/            deploy-local, sync-deployment
└── test/               Headless API flows
```

## Open work

- Wire a real Uniswap v4 PoolManager and pool (local `MockPoolManager` is a placeholder).
- Surface add / remove liquidity in the demo. The on-chain sanctions gate is already there.
- Live COA vendors and LLM.
- Broader e2e beyond the current Forge suite.
