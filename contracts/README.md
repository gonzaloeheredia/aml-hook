# contracts

Foundry workspace for the on-chain AML (Anti-Money Laundering) Hook stack (Uniswap v4).

## Layout

```text
contracts/
├── src/
│   ├── contracts/            Implementations by role
│   │   ├── hooks/            AmlHook · AmlHookSatellite · AmlHookLogic · AmlHookSettlement
│   │   ├── oracles/          ComplianceOracle          (Layer 2)
│   │   ├── policies/         RiskPolicy · LpPolicy     (Layer 3 swap / LP (liquidity provider))
│   │   ├── registries/       SanctionRegistry          (Layer 1)
│   │   ├── escrow/           FeeEscrow
│   │   ├── compensation/     LpCompensationVault
│   │   └── treasury/         ComplianceTreasury
│   ├── interfaces/           Same role subfolders (hooks/oracles/… + external/)
│   └── libraries/            RiskPolicyLib · LpPolicyLib · HookDecision · Roles · FeeBps · UsdQuote · ChainlinkFeeds · LiquidityCache
├── test/
│   ├── unit/<role>/          Mirrors src/contracts (+ by function when needed)
│   ├── unit/script/          Deploy.t.sol (AccessManager wiring)
│   ├── unit/libraries/       Roles / HookDecision ordinals / ChainlinkFeeds
│   ├── integration/          AmlStack
│   ├── mocks/                MockERC20 · MockAggregatorV3 · BareBaseHook
│   └── utils/                Helpers (AccessManager wiring + hook deploy)
├── script/                   Deploy.sol · WireFunds.s.sol · CreatePool.s.sol (+ mocks/)
├── deployments/              31337.json (Anvil) · 11155111.json + 11155111-pool.json + 11155111-funds.json (Sepolia)
├── lib/                      forge-std · v4-core · v4-periphery · openzeppelin-contracts
├── foundry.toml
└── remappings.txt
```

## Call path

```text
User → Router → PoolManager → AmlHook          (Uniswap callbacks; DELEGATECALL satellite)
                                 ├─ AmlHookSatellite   Logic + LP/swap guards (same storage prefix)
                                 ├─ AmlHookLogic       resolve → L1/L2/L3 → A–D + unscored magnitude
                                 ├─ AmlHookSettlement  take / approve / FeeEscrow.deposit
                                 ├─ SanctionRegistry (L1)
                                 ├─ ComplianceOracle (L2)  ← updateScore (oracle keeper + attestor sig)
                                 └─ RiskPolicy (L3 swap) / LpPolicyLib (L3 LP)
```

| Contract | Role |
|---|---|
| **AccessManager** | Shared OpenZeppelin authority (`Roles`: registry / oracle keepers, hook governor, compliance officer). Admin grants/revokes those roles. |
| **SanctionRegistry** | Sanctions hit → REVERT before score. New hits: `commitSanction` + `revealSanction`. `setSanctioned` remains for emergencies. |
| **ComplianceOracle** | Score / hop / origin / `feeBps` / `updatedAt`. `_ORACLE_KEEPER` submits `updateScore`; a distinct **attestor** ECDSA (Elliptic Curve Digital Signature Algorithm)-signs `attestationHash` (wallet, score, hop, origin, feeBps, updatedAt, chainid). Missing hop/origin in the sig is rejected. |
| **RiskPolicy** | Layer 3 deploy artifact. Hook hot path **calls** `decide` (external). Off-chain preview uses the same contract. Both run `RiskPolicyLib` (one memory pointer, no further CALL from inside the policy). Same mapping: ternary bands + §8.4 floors + never-scored USD (United States dollar) bands (3% / 8% / REVERT at $1,000 / $15,000). The function is pure and makes no Chainlink call. |
| **LpPolicy** | Liquidity Layer 3. Known score ignores Floor B. Never-scored reuses swap A/C/D via `LpPolicyLib`. |
| **AmlHook** | Thin CREATE2 shell (EIP-170 (Ethereum Improvement Proposal 170)). Callbacks DELEGATECALL `AmlHookSatellite`. Must call `_beginSwap` then `_endSwap` in that order. Liquidity add: L1 (Layer 1) + `LpPolicyLib` (never-scored A/C/D in afterAdd). Liquidity remove: no pause; L1 or score ≥ 71 seizes the exit into FeeEscrow 48h. Trusted router `msgSender()` is the LP (liquidity provider) subject when the caller is trusted. An untrusted periphery test router **is** the subject. Inherit Activity / Governance before Settlement (`UnitAmlHookStorageLayoutTest`). |
| **AmlHookSatellite** | Evaluation + governance bytecode. Same `poolManager` immutable as the hook. Must not be listed first as Settlement on `AmlHook` or `sanctionRegistry` aliases `complianceTreasury`. |
| **AmlHookLogic** | Subject resolve, L1→L3 (Layer 3), mitigations A–D, Chainlink USD-8 quotes (`priceFeeds`). LP adds use `LpPolicyLib`. `_HOOK_GOVERNOR` retunes operational knobs, feeds, Floor B (`setActivityWindow` / `setStalenessThreshold`), and Floor C (`setDailyWindow`). `_COMPLIANCE_OFFICER` proposes / confirms USD floors, floor fees, and the pool-impact cut (48h delay). Neither invents scores. |
| **AmlHookSettlement** | Differential take + escrow deposit / `failedDeposits` / claim / retry. Seized LP principal and fees → FeeEscrow (kinds `LpPrincipal` / `RiskFee`). Does not decide risk. |
| **FeeEscrow** | 48h hold of the FEE_OVERRIDE differential, LP-add risk fee, and seized LP principal/fees. Own owner / keepers / depositors (outside AccessManager). Checkpoint 2 reads `SanctionRegistry` / `ComplianceOracle` (no keeper bool). Clean risk fee → `LpCompensationVault`. Clean principal → the LP wallet. List or score ≥ 71 → Blocked; recover books ComplianceTreasury `ILLICIT_RISK_FEE` or `LP_PRINCIPAL` by kind. Never the pool. |
| **LpCompensationVault** | Receives clean `RiskFee` releases. Keeper closes an epoch with a merkle root of LP shares; `claim` is permissionless and refuses a listed or score ≥ 71 wallet. Unclaimed pot recycles after 90 days. |
| **ComplianceTreasury** | Two accounts: `LP_PRINCIPAL` and `ILLICIT_RISK_FEE`. Recover notify from FeeEscrow. Owner `proposePayout` / `executePayout` (48h) to an allowlisted authority destination. Never the LP vault. Events `PrincipalPosted` / `ComplianceCredited` / `PayoutProposed` / `PayoutExecuted`. |

Subject resolution (§3.5): trusted routers (`hookGovernor` `setTrustedRouter`) report the end-user via
`IMsgSender.msgSender()` as the **only** swap subject (`TrustedRouterSubjectFailed` if the call reverts or
returns zero). Uniswap `hookData` is ignored. Untrusted swap initiators revert `MissingSwapSubject`.
LP actions reuse the same `msgSender()` when the caller is a trusted router. A direct LP is `sender`.
`Deploy` registers the canonical **Universal Router** (and 2.1.1) for the current chain so swaps from
`app.uniswap.org` resolve the wallet without frontend `hookData`. Anvil has no UR (Universal Router), so it seeds
`MockTrustedRouter`. `TRUSTED_ROUTER` adds another router on top. Sepolia Deploy seeds the
canonical Universal Router. `CreatePool` still adds via `PoolModifyLiquidityTest`, which is
not trusted. Publish a 0–30 score for that address before the first mint on an empty pool
(100% impact otherwise takes 8% and `take` reverts). Live addresses: [`docs/Sepolia.md`](../docs/Sepolia.md).

### Ternary bands (§3.3)

| Score | Output | Fee settlement |
|---|---|---|
| 0–30 | ALLOW | Pool base (0.30%) |
| 31–54 | FEE_OVERRIDE | Pool base + differential (`feeBps − 30`) → FeeEscrow; keeper `feeBps` or 3% fallback |
| 55–70 | FEE_OVERRIDE | Pool base + differential; keeper `feeBps` or 8% fallback |
| 71–100 | REVERT | none |
| `updatedAt == 0` and assessed USD-8 ≥ `unscoredRevertThreshold` (default $15,000) | REVERT | Distinct error `UnscoredMagnitudeBlocked` (USD amount in the error). No live Chainlink round and no `lastFx` within 24h → `MagnitudeQuoteFailed` |

LP **add** in the 31–70 band (and never-scored 3%/8%) takes the **full** override into FeeEscrow. That path is the full override, distinct from the swap differential (`feeBps − 30`). A published 0–30 LP pays 0 extra even if the oracle row is stale (Floor B does not arm). Never-scored adds reuse Floor A / C / D. LP Floor C sums **adds** in `_lpDaily`. Those adds are never mixed with swap `_daily`.

### Roles

Two authority domains. A keeper of scores cannot move escrow fees. An escrow keeper cannot write scores.

**AccessManager**

| Role | Env | Can | Cannot |
|---|---|---|---|
| Admin | `ADMIN` (Safe in prod) | Grant / revoke roles | Write scores, sanctions, or escrow day-to-day |
| `_REGISTRY_KEEPER` | `REGISTRY_KEEPER` | Sanctions list (`commit` / `reveal` / emergency `setSanctioned`) | Publish scores, pause, touch fees |
| `_ORACLE_KEEPER` | `ORACLE_KEEPER` | Submit `updateScore` **with** a valid attestor signature | Sign the payload, sanction, retune thresholds |
| Attestor (not a manager role) | `ATTESTOR` (required; no default) | ECDSA-sign the score payload (hop + origin bound) | Submit the tx alone |
| `_HOOK_GOVERNOR` | `HOOK_GOVERNOR` | Operational thresholds, Chainlink `setPriceFeed`, trusted routers/multisigs, pause, attestor rotation | Write scores, sanctions, or policy knobs (USD floors / floor fees / pool-impact) |
| `_COMPLIANCE_OFFICER` | `COMPLIANCE_OFFICER` (48h grant delay) | Propose then confirm USD floors, floor fees, and `poolImpactThresholdBps`. `$1,000` floor on `unscoredFeeThreshold` cannot be lowered. Related pairs must keep the upper value strictly above the lower. | Write scores, sanctions, trusted routers, or score cuts (31 / 55 / 71 stay fixed). `MAX_OVERRIDE` is not adjustable. |

`ATTESTOR` must be distinct from governor, oracle keeper, and registry keeper. Deploy fails closed if it is missing or collides. Keepers, governor, and compliance officer must not overlap.

**FeeEscrow (own list)**

| Role | Can |
|---|---|
| Owner (`ADMIN` / `FEE_ESCROW_OWNER`) | Keepers (add 24h / revoke now), depositors (24h after bootstrap), auditors, tokens, LP fund, compliance reserve, `recoverBlocked` (≥7d floor, to reserve only) |
| Bootstrapper (deployer, one-shot) | `bootstrapDepositor(hook)` then cleared |
| Depositor (the hook) | `deposit` only |
| Escrow keeper | `releaseEarly` / `resolveCheckpoint2` / `releaseDefault` |
| Auditor | Read full escrow rows |

### Oracle latency (whitepaper §8.4)

Mitigations A–D elevate **ALLOW → FEE_OVERRIDE**. They never soften an existing REVERT / FEE_OVERRIDE, except A's magnitude floor and Floor C, which may REVERT:

| Code | Signal | Outcome |
|---|---|---|
| A | Score never written (`updatedAt == 0`), this swap USD < $1,000 | FEE_OVERRIDE **3%**. If the swap is more than 20% of the pool's active liquidity → **8%** |
| A mid | Same, $1,000 ≤ this swap USD < $15,000 | FEE_OVERRIDE **8%**. Same pool-drain extra → **REVERT** `UnscoredPoolImpactBlocked` |
| A + magnitude | Same, this swap USD ≥ $15,000 | **REVERT** (`UnscoredMagnitudeBlocked`) |
| A fail-closed | Never-scored and no live price and no `lastFx` within 24h | **REVERT** (`MagnitudeQuoteFailed`) |
| B first | Score older than `stalenessThreshold` (default 5 minutes), **0** settled swaps in the 1-hour window | FEE_OVERRIDE **3%**. Pool-drain extra → **8%**. Never REVERT |
| B | Same stale clock + ≥1 settled swap already in the 1-hour window | Swap + hour USD: under $1,000 → ALLOW; $1,000–$14,999 → 3%; ≥ $15,000 → 8%. Pool-drain extra: pass → 3%, 3% → 8% (ceiling; never REVERT) |
| C | Prior 24h USD > 0 and prior + this swap ≥ $15,000 (any wallet) | **REVERT** (`DailyAggregationBlocked`). LP never-scored uses the same cut on the 24h **sum of adds** (`lpDailyVolumeUsd`). |
| D | Inbound vs `lastKnownBalance` while oracle predates baseline, quoted to USD-8 | Under $1,000 → ALLOW (or ignored on never-scored, where A already charges); $1,000–$14,999 → 3%; ≥ $15,000 → 8%. Does **not** revert. On never-scored wallets the bag is the inbound (baseline 0). **Skipped** only when a published score has no baseline yet |

Defaults: `unscoredFeeThreshold = 1_000e8` ($1,000); `unscoredRevertThreshold = 15_000e8` ($15,000); `proportionalFeeBps = 300`; `punitiveFeeBps = 800`; `stalenessThreshold = 5 minutes`; `priceStalenessThreshold = 3600`; `FX_HOT_TTL = 30 minutes`; `activityWindow = 1 hour` (Floor B); `dailyWindow = 24 hours` (Floor C). Those USD floors are **8 decimals** (Chainlink). Deploy binds official ETH/USD (native + WETH) and USDC/USD on live chains. Anvil uses `MockUsdFeed`. `_HOOK_GOVERNOR` binds extra tokens via `setPriceFeed`, retunes Floor B via `setStalenessThreshold` / `setActivityWindow`, and retunes Floor C via `setDailyWindow`. `_COMPLIANCE_OFFICER` proposes then confirms (48h) the USD floors, floor fees, and `poolImpactThresholdBps`. The fee floor cannot go below $1,000. The revert floor must stay strictly above it. If `lastFx` is younger than 30 minutes the swap does **not** call Chainlink. Otherwise it reads the feed **once per token**. A missing or unusable live round uses `lastFx` (max 24h). Only with no live round and no cache within 24h does the hook fail-close (`MagnitudeQuoteFailed`).

Published score 0 (`updatedAt != 0`) is confirmed-clean. Floor A magnitude REVERT does **not** apply to a first $15,000 ticket of already-held funds. Floor C still blocks later swaps that make the 24-hour total cross $15,000.

24-hour volume is accumulated in USD-8 so ETH and USDC are not added as raw units. Small swaps that sum over $15,000 still REVERT (Floor C).

Product paths: Wallet A (exploit score 100 · `WalletBlocked`), Wallet D (inflow, B, C, $15k) and Wallet E (starts empty; fund from C; USD bands, window, feed) in [`docs/Use_Case.md`](../docs/Use_Case.md). Named-address OFAC (Office of Foreign Assets Control) (`SanctionHit`) is hook Layer 1. See the whitepaper.

REVERT does not emit a lasting log. Index custom errors on reverted txs: `SanctionHit`, `WalletBlocked` (score ≥ 71), `UnscoredMagnitudeBlocked`, `DailyAggregationBlocked`, `UnscoredPoolImpactBlocked`, `MagnitudeQuoteFailed`. `InflowMagnitudeBlocked` and `StalePoolImpactBlocked` are reserved and unused (D and B never revert).

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

Coverage (Foundry 1.7 turns off `--via-ir --optimize`; `--ir-minimum` is the escape). `FOUNDRY_PROFILE=coverage` remaps `v4-core/` to `test/coverage-stubs/` (PoolId + FullMath only) so Uniswap `Pool.sol` is never compiled. Hook callback tests and `SwapCache` (ir-minimum stack overflow of its own) are skipped. Product swaps stay on `forge test`. Logic/policy/oracle/escrow/registry are covered via `AmlHookHarness` and `HelpersCore`.

```bash
FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --offline --exclude-tests \
  --no-match-coverage '(script/|lib/|src/contracts/hooks/AmlHook\.sol)' \
  --report summary --report lcov
```

Production compile is unchanged: `via_ir = true`, `optimizer_runs = 200`. No profile needed for `forge test` / `forge build`.

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
  --rpc-url http://127.0.0.1:8545 --broadcast --disable-code-size-limit
cd ..
node scripts/sync-deployment.mjs
```

Deployer = Anvil account #0 (local defaults for admin / registry keeper / oracle keeper / hook governor / compliance officer unless overridden). Production **must** set:

| Env | Purpose |
|---|---|
| `ATTESTOR` | Required. Distinct ECDSA attestor. No default. A missing value fails the script. |
| `ADMIN` or `FEE_ESCROW_OWNER` | FeeEscrow + AccessManager admin from genesis (Safe). Not the configurer EOA (externally owned account). |
| `LP_COMPENSATION_FUND` | Unused on a fresh Deploy. Clean releases go to the deployed `LpCompensationVault`. Sepolia additive path: `script/WireFunds.s.sol`. |
| `COMPLIANCE_RESERVE` | Unused. Recovered Blocked (confirmed-illicit) destination is `ComplianceTreasury` (wired as `FeeEscrow.complianceReserve`), never the LP fund. |
| `MAX_SCORE_AGE` | Floor B `stalenessThreshold` at deploy. Script default is 5 minutes. If this is 0, the hook constructor falls back to `DEFAULT_STALENESS` (5 minutes). |
| `REGISTRY_KEEPER` / `ORACLE_KEEPER` / `HOOK_GOVERNOR` / `COMPLIANCE_OFFICER` | Split keys. Deploy verifies they do not overlap. Officer grant is 48h. |
| `POOL_MANAGER` | Real `IPoolManager`. Unset → `MockPoolManager` (no live swaps). Sepolia: official `0xE03A1074…3543`. |
| `FEE_TOKEN` | FeeEscrow custody asset. Unset → mintable `MockUSDC` (6 decimals). Sepolia reuse: already-deployed MockUSDC. |
| `WETH_TOKEN` | Demo ETH token. Unset → mintable `MockWETH` (18 decimals), bound to the ETH/USD feed ($1,000 on Anvil). Not native gas. |
| `ETH_USD_FEED` / `TOKEN_USD_FEED` | Optional overrides for Chainlink AggregatorV3. Unset → official ETH/USD, USDC/USD, and WETH bindings for the chain. MockUSDC is not canonical USDC. Set `TOKEN_USD_FEED` to the chain's USDC/USD proxy or the fee token has no feed. |

`bootstrapDepositor` runs in the same deploy tx so the first FEE_OVERRIDE `deposit` does not wait 24h.

On chainid 31337 the script deploys `MockUSDC` + `MockWETH` and binds `MockUsdFeed` ($1 USDC, $1000 ETH). Wallets A–E are Anvil **#1–#5**. Wallet A is not listed. The COA (Compliance Officer Agent) publishes score 100 so pool swaps hit `WalletBlocked`. The API (application programming interface) then mints USDC and MockWETH balances (E starts at 0 USDC. Fund from C or **Mint** in MetaMask). `POST /demo/mint` and the MetaMask **Mint 1,000 USDC** / **Mint 1 ETH** buttons call `mint` on those tokens. That path is still distinct from a live `PoolManager` fill.

On other chains Deploy binds official Chainlink Data Feeds: ETH/USD on `address(0)` and canonical WETH, USDC/USD on native USDC. Extra pool tokens still need `_HOOK_GOVERNOR` `setPriceFeed`. If `lastFx` is younger than 30 minutes (`FX_HOT_TTL`), the swap does not call Chainlink. Otherwise never-scored magnitude and Mitigation D quote to USD-8 from **one** `latestRoundData` per token. Every amount in that swap uses that price. A usable round is stored in `lastFx`. Unbind or a dead aggregator falls back to that cache until `MAX_PRICE_STALENESS` (24h). No live round and no fresh cache → `MagnitudeQuoteFailed`. `PriceFallbackUsed` logs heartbeat-stale live rounds and the 24h cache path.

Writes `contracts/deployments/<chainId>.json`. Anvil (`31337`) is copied to `packages/sdk/deployments/` by `sync-deployment.mjs`. Sepolia writes `11155111.json` only under `contracts/deployments/`. The SDK does not load it.

## Sepolia (live PoolManager)

Set `POOL_MANAGER`, reuse `FEE_TOKEN` / `WETH_TOKEN`, and bind `TOKEN_USD_FEED` (MockUSDC). Then:

```bash
cd contracts
forge script script/Deploy.sol:Deploy --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
# After a 0–30 oracle row on the liquidity router (empty-pool first add):
forge script script/CreatePool.s.sol:CreatePool --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
```

`CreatePool` initializes MockWETH/MockUSDC, `DYNAMIC_FEE_FLAG`, tick spacing 60, mints to the LP, and deposits 0.1 WETH + 100 USDC. Addresses and txs: [`docs/Sepolia.md`](../docs/Sepolia.md).

Foundry loads `contracts/.env`. If `FEE_TOKEN` / `WETH_TOKEN` / `TOKEN_USD_FEED` are set, `UnitDeployTest` cases that expect Anvil to deploy fresh mocks (or leave the mainnet MockUSDC feed unbound) fail. Unset those three for a clean `forge test`.

The CREATE2 address mined by `Deploy.sol` changed versus earlier deploys: the flag bitmask now includes `BEFORE_ADD_LIQUIDITY_FLAG`, `AFTER_ADD_LIQUIDITY_FLAG`, `AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG`, `BEFORE_REMOVE_LIQUIDITY_FLAG`, `AFTER_REMOVE_LIQUIDITY_FLAG`, and `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG` in addition to the swap flags. An address mined with the previous bitmask will not match the hook's current permissions.

## Boundary

| Layer | Role |
|---|---|
| `apps/api` | COA (Claude or skill interpreter) → signed `updateScore`; `previewSwap` / `observeSwap`; defers D for latency demo. Anvil: keeper #0 + attestor #9. Sepolia: `ORACLE_CHAIN_ID=11155111` + role keys |
| `contracts/` | On-chain ALLOW / FEE_OVERRIDE / REVERT + §8.4 floors + Chainlink USD magnitude. Anvil uses `MockPoolManager` unless `POOL_MANAGER` is set. Sepolia uses the official Uniswap v4 manager |
| `packages/sdk` | Shared ABIs (application binary interfaces) / addresses for api + frontend |
