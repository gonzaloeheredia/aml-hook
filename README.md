# AML Hook

Uniswap v4 hook that evaluates the swap subject at execution and returns a ternary decision: **ALLOW**, **FEE_OVERRIDE**, or **REVERT**.

The hook does not compute risk on-chain. An off-chain keeper (Compliance Officer Agent) writes a score into `ComplianceOracle`. `beforeSwap` reads that row, applies sanctions and latency floors, and either lets the swap through, takes a risk differential into `FeeEscrow`, or reverts. Liquidity add and remove are a sanctions-only gate. They do not read the score.

Built for UHI10.

## Documentation

The product thesis and the executable scenario live in `docs/`. Read those before the contracts.

| Document | Contents |
| --- | --- |
| [`docs/Whitepaper.md`](docs/Whitepaper.md) | Problem, architecture, roles, FeeEscrow, latency floors, regulatory framing, and competitive map |
| [`docs/Use_Case.md`](docs/Use_Case.md) | Five-wallet run of the whitepaper: exploit, N-hop, D floors (B/C/inflow/$15k), E bands + window + feed, Opinion |

Supporting notes:

| Document | Contents |
| --- | --- |
| [`contracts/README.md`](contracts/README.md) | Foundry layout, call path, roles |
| [`apps/api/README.md`](apps/api/README.md) | Anvil adapter and keeper |
| [`apps/frontend/README.md`](apps/frontend/README.md) | Guided UI |
| [`agents/oracle-coa/`](agents/oracle-coa/) | COA skill specs |

## Decision surface

| Condition | Output | Settlement |
| --- | --- | --- |
| Score 0–30, published and fresh | ALLOW | Pool fee 0.30% |
| Score 31–70 | FEE_OVERRIDE | Pool keeps 0.30%. Extra slice → FeeEscrow (48h). Clean exit → LP compensation fund. Confirmed illicit → compliance reserve |
| Score 71–100 | REVERT | No swap |
| Sanctions list | REVERT | No swap. Score is not read |
| Published 0 + inbound USD under $1,000 | ALLOW | Floor D dust |
| Published 0 + inbound USD $1,000–$14,999 | FEE_OVERRIDE 3% | Floor D mid |
| Published + inbound USD ≥ $15,000, score still older than the baseline | FEE_OVERRIDE 8% | Floor D large. Does not revert |
| Score older than `stalenessThreshold` (default 5 minutes) and at least one prior swap in the hour | pass / 3% / 8% by swap+hour USD | Floor B. Never reverts. 20% pool extra hardens the band and stops at 8%. |
| Prior 24h USD + this swap crosses $15,000 | REVERT | Floor C `DailyAggregationBlocked` |
| Never written, assessed USD &lt; $1,000 | FEE_OVERRIDE 3% | Unknown wallet (use-case wallet E) |
| Never written, $1,000–$14,999 | FEE_OVERRIDE 8% | Unknown wallet |
| Never written, this swap ≥ $15,000 | REVERT | `UnscoredMagnitudeBlocked` |
| Never written, no usable USD price | REVERT | `MagnitudeQuoteFailed` |

A published score of 0 is confirmed clean. An address with no oracle row is unknown. Those are different paths. The 3% / 8% and $1,000 / $15,000 figures above are deploy defaults; `_COMPLIANCE_OFFICER` proposes then confirms retunes (48h). Score cuts 31 / 55 / 71 stay fixed. Full thresholds: whitepaper §8.4. The A–E walkthrough: use case. Fee escrow destinations: §8.3.

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
| `AccessManager` | Shared authority for registry, oracle, hook governor, and compliance officer |

Subject resolution uses a trusted router (`IMsgSender.msgSender()`). Uniswap `hookData` is ignored. An untrusted initiator reverts before any layer runs.

Writes are split so a score keeper cannot move escrow, and an escrow keeper cannot publish scores. `updateScore` requires `_ORACLE_KEEPER` plus a distinct attestor signature over wallet, score, hop, origin, fee, timestamp, and chain id.

## Demo wallets

The frontend talks to the API. The API reads and writes the use-case ledger on Anvil (wallets A–E = accounts #1–#5).

| Wallet | Starting state | What to try |
| --- | --- | --- |
| A | Confirmed exploit, score 100 (not OFAC-listed) | Pool swap → `WalletBlocked`. P2P can contaminate B, C, D. Do not fund E from A |
| B | Clean, score 0 | Receive from A → ~65 / 8%. Receive from tainted C → ~42 / 3% |
| C | Clean, score 0, 50,000 USDC | Fund E (unknown) or D (inflow). Receive from A → ~65 / 8% |
| D | Published score 0, 5,000 USDC | Held funds → ALLOW. Clean C→D $10k → 3%; $15k → 8% (no hop). Advance 5 min after a swap → Floor B |
| E | Never written, empty | Fund from C. C→E $500 → 3%; $10k then $1k swap → 8% (A mid); $15k bag + small swap → 8% (D); $15k this swap → revert |

## Quick start

```bash
npm install

# required — Anvil, AccessManager-wired stack, keeper env for the API
npm run deploy:local

npm run dev:api        # http://localhost:4000
npm run dev:frontend   # http://localhost:3000
```

`NEXT_PUBLIC_API_URL` defaults to `http://localhost:4000`. After `deploy:local`, restart the API so it loads `apps/api/.env.local`. Without Anvil the API returns `503` `{ error: "deploy_local" }`.

```bash
curl http://127.0.0.1:4000/health
# mode: "anvil"  ·  scoreSource: "onchain"  ·  chain.ok: true
```

| Package | Path | Role |
| --- | --- | --- |
| Contracts | [`contracts/`](contracts/README.md) | Foundry. `forge test` · `script/Deploy.sol` |
| API / keeper | [`apps/api/`](apps/api/README.md) | Anvil adapter + COA + signed `updateScore` |
| Frontend | [`apps/frontend/`](apps/frontend/README.md) | Six-stage demo |
| SDK | [`packages/sdk/`](packages/sdk/README.md) | ABIs + `getDeployment(31337)` |
| Headless flows | [`test/`](test/README.md) | HTTP scripts against the API. Not Forge |

`test/` is Node against the API. `contracts/test/` is Solidity (`forge test`).

## What is real vs mocked

| Piece | Status |
| --- | --- |
| AccessManager, SanctionRegistry, ComplianceOracle, RiskPolicy, AmlHook, FeeEscrow | Deployed contracts |
| Liquidity sanctions gate | On-chain. Demo UI is still swap-only |
| PoolManager | Local `MockPoolManager` unless `POOL_MANAGER` is set. Demo swap is `previewSwap` + `observeSwap` + FeeEscrow deposit — not a live Uniswap fill |
| `updateScore` | Signed tx (keeper #0 + attestor #9) |
| Demo balances, P2P, quotes, escrow rows | Anvil. P2P is ERC-20 `transfer` |
| USD quotes | Anvil: `MockUsdFeed` ($1 fee token, $1000 ETH). Live chain: official Chainlink ETH/USD + USDC/USD. Extra tokens: governor `setPriceFeed` |
| Policy knobs (USD floors, floor fees, pool-impact) | `_COMPLIANCE_OFFICER` propose → 48h confirm. Score cuts 31 / 55 / 71 stay fixed |
| COA opinion | Deterministic stand-in. No live LLM or vendor feeds |

## Local deploy

```bash
npm run deploy:local
```

1. Starts Anvil on `:8545`.
2. Deploys AccessManager, L1/L2/L3, AmlHook (CREATE2), and FeeEscrow. Uses `MockPoolManager` unless `POOL_MANAGER` is set. On Anvil binds `MockUsdFeed` ($1 fee token, $1000 ETH). On a live chain binds official Chainlink ETH/USD, WETH, and USDC/USD. Seeds wallets A–E (Anvil #1–#5).
3. Wires roles. Anvil account #0 is the default admin / keepers / governor / compliance officer. Anvil #9 is the local attestor. Production requires a distinct `ATTESTOR`, a Safe as `ADMIN` or `FEE_ESCROW_OWNER`, a dedicated `COMPLIANCE_OFFICER` (48h grant delay), and a dedicated `COMPLIANCE_RESERVE` (never the LP fund). Floor B default is 5 minutes (`DEFAULT_STALENESS` / `MAX_SCORE_AGE`). Institutional pools may tighten to 120 seconds.
4. Writes `contracts/deployments/31337.json` (hook, escrow, fee token, feeds, wallets, attestor) and copies it into `packages/sdk/deployments/`.
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
├── apps/api/           Anvil adapter, COA, keeper
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
