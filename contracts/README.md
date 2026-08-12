# contracts

Foundry workspace for the on-chain AML Hook stack (Uniswap v4).

## Layout

```text
contracts/
├── src/
│   ├── contracts/            Implementations by role
│   │   ├── hooks/            AmlHook · AmlHookLogic
│   │   ├── oracles/          ComplianceOracle          (Layer 2)
│   │   ├── policies/         RiskPolicy                (Layer 3)
│   │   ├── registries/       SanctionRegistry          (Layer 1)
│   │   ├── escrow/           FeeEscrow
│   │   └── external/         BaseHook
│   ├── interfaces/           Same role subfolders (hooks/oracles/… + external/)
│   └── libraries/            HookDecision · Roles
├── test/
│   ├── unit/<role>/          Mirrors src/contracts (+ by function when needed)
│   ├── unit/Deploy.t.sol     Deploy wiring / AccessManager verification
│   ├── integration/          AmlStack
│   ├── mocks/                MockERC20
│   └── utils/                Helpers (AccessManager wiring + hook deploy)
├── script/                   Deploy.sol (+ mocks/)
├── lib/                      forge-std · v4-core · v4-periphery · openzeppelin-contracts
├── foundry.toml
└── remappings.txt
```

## Call path

```text
User → Router → PoolManager → AmlHook
                                 ├─ SanctionRegistry (L1)
                                 ├─ ComplianceOracle (L2)  ← updateScore (oracle keeper)
                                 └─ RiskPolicy (L3)        ← score + latency floors
```

| Contract | Role |
|---|---|
| **AccessManager** | Shared OpenZeppelin authority (`Roles`: registry / oracle keepers, hook governor) |
| **SanctionRegistry** | Sanctions hit → REVERT before score |
| **ComplianceOracle** | Score / hop / origin / `feeBps` / `updatedAt`; keeper writes |
| **RiskPolicy** | Ternary bands + §3.8 floors (stale+activity, significant inflow) |
| **AmlHook** / **AmlHookLogic** | `beforeSwap` / `afterSwap`; `lpFeeOverride`; inflow baseline |
| **FeeEscrow** | Separate owner / keepers / depositors (not on the shared AccessManager) |

Subject resolution (§3.5): trusted routers (`hookGovernor` `setTrustedRouter`) report the end-user via
`IMsgSender.msgSender()` as the primary source; `hookData` (`abi.encode(endUser)`) is a cross-check
when both are present (`SubjectMismatch` on disagreement) and the fail-closed fallback otherwise.

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
forge install OpenZeppelin/openzeppelin-contracts --no-git --shallow
forge build
forge test
```

Focused latency / policy / deploy tests:

```bash
forge test --match-contract "UnitRiskPolicyDecideTest|UnitRiskPolicyLatencyFloorTest|UnitAmlHookLogicTest|UnitDeployTest" -vv
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
forge script script/Deploy.sol:Deploy \
  --rpc-url http://127.0.0.1:8545 --broadcast
cd ..
node scripts/sync-deployment.mjs
```

Deployer = Anvil account #0 (defaults for admin / registry keeper / oracle keeper / hook governor unless overridden via env).  
Writes `contracts/deployments/31337.json` and copies to `packages/sdk/deployments/`.

## Boundary

| Layer | Role |
|---|---|
| `apps/api` | Oracle Keeper — mock trail or real `updateScore` tx; defers D for latency demo |
| `contracts/` | On-chain ALLOW / FEE_OVERRIDE / REVERT + §3.8 floors |
| `packages/sdk` | Shared ABIs / addresses for api + frontend |
