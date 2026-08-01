# contracts

Foundry workspace for the on-chain AML Hook stack (Uniswap v4).

## Layout

```text
contracts/
├── src/
│   ├── interfaces/     ISanctionRegistry · IComplianceOracle · IRiskPolicy
│   ├── libraries/      HookDecision
│   ├── registries/     SanctionRegistry          (Layer 1)
│   ├── oracle/         ComplianceOracle          (Layer 2)
│   ├── policy/         RiskPolicy                (Layer 3)
│   └── hooks/
│       ├── BaseHook.sol      # PoolManager-gated IHooks
│       ├── AmlHookLogic.sol  # L1 → L2 → L3
│       └── AmlHook.sol       # beforeSwap / afterSwap
├── test/               AmlStack.t.sol · AmlHook.t.sol
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
                                 └─ RiskPolicy (L3)
```

| Contract | Role |
|---|---|
| **SanctionRegistry** | Sanctions hit → REVERT before score |
| **ComplianceOracle** | Score / hop / origin; keeper writes |
| **RiskPolicy** | `0–30` ALLOW · `31–70` FEE_OVERRIDE · `71–100` REVERT |
| **AmlHook** | `beforeSwap` / `afterSwap`; `lpFeeOverride` via `OVERRIDE_FEE_FLAG` |

`hookData` should be `abi.encode(wallet)` so the subject is the end user (not the router).

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
| `apps/api` | Oracle Keeper — mock trail or real `updateScore` tx (see root README) |
| `contracts/` | On-chain ALLOW / FEE_OVERRIDE / REVERT |
| `packages/sdk` | Shared names / types for api + frontend |
