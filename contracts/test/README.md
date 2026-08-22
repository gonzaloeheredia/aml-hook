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
| `unit/hooks/` | `AmlHook`, `AmlHookLogic` (incl. Chainlink USD quotes, missing/stale feed fail-closed, three never-scored bands), resolve-wallet, FeeEscrow take path, afterSwap cache |
| `unit/oracles/` | `ComplianceOracle` (fuzz + role isolation) |
| `unit/policies/` | `RiskPolicy.decide` + latency floors + never-scored USD bands (3% / 8% / REVERT) |
| `unit/registries/` | `SanctionRegistry` (fuzz + isolation) |
| `unit/libraries/` | `Roles` + `HookDecision` ordinals |
| `unit/script/` | `Deploy.sol` AccessManager wiring |
| `integration/` | Full stack evaluate path (A/B/C bands) |
| `utils/` | Shared fixtures (`Helpers`, `HookPoolManagerStub`) |
| `mocks/` | Test-only ERC-20s + `MockAggregatorV3` (Chainlink stand-in) |

Interfaces under `src/interfaces/` are exercised via their implementers (no dedicated suite).

```bash
cd contracts
forge test
```
