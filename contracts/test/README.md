# Foundry tests (`contracts/test/`)

Mirrors `src/` so each production surface has a matching unit folder:

```
src/contracts/                  test/unit/
├── escrow/                     ├── escrow/
├── external/                   ├── external/
├── hooks/                      ├── hooks/
├── oracles/                    ├── oracles/
├── policies/                   ├── policies/
└── registries/                 └── registries/

src/libraries/                  test/unit/libraries/
script/                         test/unit/script/
```

| Folder | Covers |
|---|---|
| `unit/escrow/` | `FeeEscrow` lifecycle + admin |
| `unit/external/` | Official `v4-periphery` BaseHook gating / `HookNotImplemented` |
| `unit/hooks/` | `AmlHook`, `AmlHookLogic` (incl. Chainlink USD quotes, missing/stale feed fail-closed, three never-scored bands), resolve-wallet, FeeEscrow take path, afterSwap cache. `AmlHookLogic.ComplianceParams` covers `_COMPLIANCE_OFFICER` propose / 48h confirm, FATF $1,000 floor, pair ordering, and live fees / USD / pool-impact flowing into `evaluate`. |
| `unit/oracles/` | `ComplianceOracle` (fuzz + role isolation) |
| `unit/policies/` | `RiskPolicy.decide` + latency floors + never-scored USD bands (3% / 8% / REVERT). `RiskPolicy.FloorFees` covers the 12-arg form: live proportional / punitive fees, score cuts 31 / 55 / 71 stay fixed, `MAX_OVERRIDE` caps only keeper `recommendedFeeBps`. |
| `unit/registries/` | `SanctionRegistry` (fuzz + isolation) |
| `unit/libraries/` | `Roles` + `HookDecision` ordinals + `FeeBps` / `UsdQuote` / `PoolImpact` / `SwapCache` (store-load-clear + fuzz) + `ChainlinkFeeds` / `UniversalRouters` (live quote if `MAINNET_RPC_URL` is set) |
| `unit/script/` | `Deploy.sol` AccessManager wiring (four roles, officer 48h, Chainlink vs `MockUsdFeed`) |
| `integration/` | Full stack evaluate path (A/B/C bands), compliance-officer retune, and `AmlStack.Relations` (L1→L2→L3→hook→FeeEscrow + role isolation + fuzz agreement) |
| `utils/` | Shared fixtures (`Helpers`, `HookPoolManagerStub`) |
| `mocks/` | Test-only ERC-20s + `MockAggregatorV3` (Chainlink stand-in) |

Interfaces under `src/interfaces/` are exercised via their implementers (no dedicated suite).

```bash
cd contracts
forge test --threads 2
```
