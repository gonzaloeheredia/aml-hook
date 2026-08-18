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
│   │   └── external/         (third-party adapters live under lib/; no local BaseHook)
│   ├── interfaces/           Same role subfolders (hooks/oracles/… + external/)
│   └── libraries/            HookDecision · Roles
├── test/
│   ├── unit/<role>/          Mirrors src/contracts (+ by function when needed)
│   ├── unit/script/          Deploy.t.sol (AccessManager wiring)
│   ├── unit/libraries/       Roles / HookDecision ordinals
│   ├── integration/          AmlStack
│   ├── mocks/                MockERC20 · BareBaseHook
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
| **AmlHook** / **AmlHookLogic** | `beforeSwap` / `afterSwap` (+ `afterSwapReturnDelta`); pool standard fee; differential → FeeEscrow; inflow baseline |
| **FeeEscrow** | 48h hold of FEE_OVERRIDE differential only; own owner / keepers / depositors (not AccessManager); sanction confirmed → blocked reserve; else `lpCompensationFund` (`releaseEarly` / `resolveCheckpoint2(false)` / `releaseDefault`); never the pool |

Subject resolution (§3.5): trusted routers (`hookGovernor` `setTrustedRouter`) report the end-user via
`IMsgSender.msgSender()` as the **only** subject (`TrustedRouterSubjectFailed` if the call reverts or
returns zero). Uniswap `hookData` is ignored. Untrusted initiators revert `MissingSwapSubject`.
`Deploy` registers the canonical **Universal Router** (and 2.1.1) for the current chain so swaps from
`app.uniswap.org` resolve the wallet without frontend `hookData`. Anvil has no UR, so it seeds
`MockTrustedRouter`. `TRUSTED_ROUTER` adds another router on top.

### Ternary bands (§3.3)

| Score | Output | Fee settlement |
|---|---|---|
| 0–30 | ALLOW | Pool base (0.30%) |
| 31–70 | FEE_OVERRIDE | Pool base + differential (`feeBps − 30`) → FeeEscrow; keeper `feeBps` or ~8% / ~3% hop fallbacks |
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
