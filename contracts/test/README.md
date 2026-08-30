# Foundry tests (`contracts/test/`)

Mirrors `src/` so each production surface has a matching unit folder:

```
src/contracts/                  test/unit/
├── escrow/                     ├── escrow/
├── compensation/               ├── compensation/
├── treasury/                   ├── treasury/
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
| `unit/escrow/` | `FeeEscrow` lifecycle + admin + fuzz (Checkpoint 2 reads oracle/list; clean default → LP (liquidity provider) fund; blocked recover → treasury `ILLICIT_RISK_FEE`) |
| `unit/compensation/` | `LpCompensationVault` accrue / epoch merkle claim / illicit refuse / recycle |
| `unit/treasury/` | `ComplianceTreasury` two-account ledger plus delayed allowlisted payouts |
| `unit/external/` | Official `v4-periphery` BaseHook gating / `HookNotImplemented` |
| `unit/policies/` | `RiskPolicyLib.decide` / `RiskPolicy.decide` (swaps) and `LpPolicyLib.decide` / `LpPolicy.decide` (LP: known score ignores Floor B; never-scored matches swap A/C/D). |
| `unit/hooks/` | `AmlHook`, `AmlHookLogic` (including 30-minute hot `lastFx` skip, one Chainlink read per token when the cache is older, 24h fallback, missing-feed fail-closed, three never-scored bands), resolve-wallet, FeeEscrow take path, afterSwap cache. `AmlHookLogic.Admin` covers constructor defaults, pause, governor setters. `AmlHookLogic.Fuzz` matches `evaluate` to `RiskPolicy.decide` (published score, never-scored USD (United States dollar), Floor B/C). `AmlHookLogic.ComplianceParams` covers `_COMPLIANCE_OFFICER` propose / 48h confirm, FATF (Financial Action Task Force) $1,000 floor, pair ordering, and live fees / USD / pool-impact flowing into `evaluate`. `AmlHook.Liquidity` covers LP add fees, never-scored Floor A, pause (clean mint allowed), seized remove → FeeEscrow 48h. `AmlHook.StorageLayout` locks satellite slot 1 = `sanctionRegistry` (`complianceTreasury` is a different slot). |
| `unit/oracles/` | `ComplianceOracle` (fuzz + role isolation + attestation hash binding) |
| `unit/registries/` | `SanctionRegistry` (fuzz + isolation + commit-reveal) |
| `unit/libraries/` | `Roles` + `HookDecision` ordinals + `FeeBps` / `UsdQuote` / `PoolImpact` / `ChainlinkFeeds` / `UniversalRouters` (unit + fuzz). `SwapCache` EIP-1153 (Ethereum Improvement Proposal 1153) beforeSwap → afterSwap snapshot. `ChainlinkFeeds.t.sol` live quote if `MAINNET_RPC_URL` is set. |
| `unit/script/` | `Deploy.sol` AccessManager wiring (four roles, officer 48h, Chainlink vs `MockUsdFeed`). Assumes unset `FEE_TOKEN` / `WETH_TOKEN` / `TOKEN_USD_FEED`. Foundry loads `contracts/.env`, so a Sepolia env file trips the Anvil-mock assertions. |
| `integration/` | Full stack evaluate path (A/B/C bands) plus compliance-officer retune of USD / floor fees. `AmlStack.Relations` covers L1 (Layer 1) → L2 (Layer 2) → L3 (Layer 3) → hook → FeeEscrow, role isolation, Floor B/C vs policy. Liquidity add/remove screen L1, score bands, and never-scored Floor A. A blocked remove seizes principal and fees into FeeEscrow 48h. |
| `utils/` | Shared fixtures (`Helpers`, `HookPoolManagerStub`) |
| `mocks/` | Test-only ERC-20s + `MockAggregatorV3` (Chainlink stand-in) |

Interfaces under `src/interfaces/` are exercised via their implementers. There is no dedicated interface suite.

```bash
cd contracts
forge test
```
