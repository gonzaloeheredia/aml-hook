# contracts

Foundry workspace for the on-chain AML Hook stack (Uniswap v4).

## Layout

```text
contracts/
├── src/
│   ├── interfaces/     ISanctionRegistry · IComplianceOracle · IRiskPolicy
│   ├── libraries/      HookDecision (ALLOW / FEE_OVERRIDE / REVERT)
│   ├── registries/     SanctionRegistry          (Layer 1)
│   ├── oracle/         ComplianceOracle          (Layer 2)
│   ├── policy/         RiskPolicy                (Layer 3)
│   └── hooks/
│       ├── BaseHook.sol      # PoolManager-gated IHooks
│       ├── AmlHookLogic.sol  # L1 → L2 → L3 + §3.8 latency signals
│       └── AmlHook.sol       # beforeSwap / afterSwap
├── test/               AmlStack · AmlHook · RiskPolicy · OracleLatency
├── script/             DeployAmlStack.s.sol
├── lib/                forge-std · v4-core · v4-periphery (local, gitignored)
├── foundry.toml
└── remappings.txt
```

## Call path

```text
User → Router → PoolManager → AmlHook
                                 ├─ SanctionRegistry (L1)
                                 ├─ ComplianceOracle (L2)  ← updateScore (keeper)
                                 └─ RiskPolicy (L3)        ← score + latency floors
```

| Contract | Role |
|---|---|
| **SanctionRegistry** | Sanctions hit → REVERT before score |
| **ComplianceOracle** | Score / hop / origin / `feeBps` / `updatedAt`; keeper writes |
| **RiskPolicy** | Ternary bands + §3.8 floors (stale+activity, significant inflow) |
| **AmlHook** / **AmlHookLogic** | `beforeSwap` / `afterSwap`; `lpFeeOverride`; inflow baseline |

`hookData` must be `abi.encode(endUser)` — never the router (§3.5 fail-closed).

### Ternary bands (§3.3)

| Score | Output | Fee |
|---|---|---|
| 0–30 | ALLOW | Pool base (0.30%) |
| 31–70 | FEE_OVERRIDE | Keeper `feeBps`, else ~8% (1-hop) / ~3% (2-hop) |
| 71–100 | REVERT | — |

### Oracle latency (§3.8)

Mitigations elevate **ALLOW → FEE_OVERRIDE** only (never soften REVERT):

| Code | Signal |
|---|---|
| A | Score never written (`updatedAt == 0`) |
| B | Stale score + pool activity in window |
| C | Activity-window cap (`maxOpsInWindow`) |
| D | Significant inflow vs `lastKnownBalance` while oracle predates baseline |

Default latency / inflow fee when keeper omitted `feeBps`: **8%** (`LATENCY_FEE_BPS = 800`). Product path for Wallet D in [`docs/Use_Case.md`](../docs/Use_Case.md) §7.

## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge` on PATH).

```bash
cd contracts
forge install foundry-rs/forge-std --no-git --shallow
forge install Uniswap/v4-core --no-git --shallow
forge install Uniswap/v4-periphery --no-git --shallow
forge build
forge test
```

Focused latency / policy tests:

```bash
forge test --match-contract "RiskPolicyTest|OracleLatencyTest" -vv
```

## Local deploy (Anvil + keeper)

From repo root (starts Anvil if needed, deploys stack, syncs SDK + `apps/api/.env.local`):

```bash
npm run deploy:local
```

Manual:

```bash
anvil   # :8545
cd contracts
forge script script/DeployAmlStack.s.sol:DeployAmlStack \
  --rpc-url http://127.0.0.1:8545 --broadcast
cd ..
node scripts/sync-deployment.mjs
```

Deployer = Anvil account #0 = keeper on `ComplianceOracle`.  
Writes `contracts/deployments/31337.json` and copies to `packages/sdk/deployments/`.

## Boundary

| Layer | Role |
|---|---|
| `apps/api` | Oracle Keeper — mock trail or real `updateScore` tx; defers D for latency demo |
| `contracts/` | On-chain ALLOW / FEE_OVERRIDE / REVERT + §3.8 floors |
| `packages/sdk` | Shared ABIs / addresses for api + frontend |
