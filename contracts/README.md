# contracts

Foundry workspace for the on-chain AML Hook stack (Uniswap v4).

## Layout

```text
contracts/
├── src/
│   ├── contracts/            Implementations by role
│   │   ├── hooks/            AmlHook · AmlHookLogic · AmlHookSettlement
│   │   ├── oracles/          ComplianceOracle          (Layer 2)
│   │   ├── policies/         RiskPolicy                (Layer 3)
│   │   ├── registries/       SanctionRegistry          (Layer 1)
│   │   ├── escrow/           FeeEscrow
│   │   └── external/         (third-party adapters live under lib/; no local BaseHook)
│   ├── interfaces/           Same role subfolders (hooks/oracles/… + external/)
│   └── libraries/            HookDecision · Roles · FeeBps · UsdQuote
├── test/
│   ├── unit/<role>/          Mirrors src/contracts (+ by function when needed)
│   ├── unit/script/          Deploy.t.sol (AccessManager wiring)
│   ├── unit/libraries/       Roles / HookDecision ordinals
│   ├── integration/          AmlStack
│   ├── mocks/                MockERC20 · MockAggregatorV3 · BareBaseHook
│   └── utils/                Helpers (AccessManager wiring + hook deploy)
├── script/                   Deploy.sol (+ mocks/)
├── lib/                      forge-std · v4-core · v4-periphery · openzeppelin-contracts
├── foundry.toml
└── remappings.txt
```

## Call path

```text
User → Router → PoolManager → AmlHook          (Uniswap callbacks only)
                                 ├─ AmlHookLogic       resolve → L1/L2/L3 → A–D + unscored magnitude
                                 ├─ AmlHookSettlement  take / approve / FeeEscrow.deposit
                                 ├─ SanctionRegistry (L1)
                                 ├─ ComplianceOracle (L2)  ← updateScore (oracle keeper + attestor sig)
                                 └─ RiskPolicy (L3)        ← score + latency floors + never-scored USD 3%/8%/REVERT
```

| Contract | Role |
|---|---|
| **AccessManager** | Shared OpenZeppelin authority (`Roles`: registry / oracle keepers, hook governor). Admin grants/revokes those roles. |
| **SanctionRegistry** | Sanctions hit → REVERT before score. New hits: `commitSanction` + `revealSanction`. `setSanctioned` remains for emergencies. |
| **ComplianceOracle** | Score / hop / origin / `feeBps` / `updatedAt`. `_ORACLE_KEEPER` submits `updateScore`; a distinct **attestor** ECDSA-signs `attestationHash` (wallet, score, hop, origin, feeBps, updatedAt, chainid). Missing hop/origin in the sig is rejected. |
| **RiskPolicy** | Ternary bands + §8.4 floors (stale+activity, significant inflow) + never-scored USD bands (3% / 8% / REVERT at $1,000 / $25,000). Pure — no Chainlink call. |
| **AmlHook** | Uniswap callbacks only. Must call `_beginSwap` then `_endSwap` in that order. |
| **AmlHookLogic** | Subject resolve, L1→L3, mitigations A–D, Chainlink USD-8 quotes (`priceFeeds`). `_HOOK_GOVERNOR` retunes thresholds, feeds, and Mitigation C (`setActivityWindow`); cannot invent scores. |
| **AmlHookSettlement** | Differential take + escrow deposit / `failedDeposits` / claim / retry. Does not decide risk. |
| **FeeEscrow** | 48h hold of the FEE_OVERRIDE differential only. Own owner / keepers / depositors (not AccessManager). Owner is `ADMIN` / `FEE_ESCROW_OWNER` from genesis (Safe in prod), not the deploying EOA. Hook is wired as depositor via one-shot `bootstrapDepositor` (no 24h wait). Later depositor changes: 24h. Add keeper: 24h; revoke keeper: immediate. Clean / early / default → `lpCompensationFund`. Sanction confirmed → Blocked; owner `recoverBlocked` waits `min(blockedRecoveryDelay, 7 days)` and pays `complianceReserve` only. Never the LP fund. Never the pool. |

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
| `updatedAt == 0` and assessed USD-8 ≥ `unscoredRevertThreshold` (default $25,000) | REVERT | Distinct error `UnscoredMagnitudeBlocked` (USD amount in the error). Missing/stale Chainlink feed → `MagnitudeQuoteFailed` |

### Roles

Two casilleros. A keeper of scores cannot move escrow fees, and the reverse.

**AccessManager**

| Role | Env | Can | Cannot |
|---|---|---|---|
| Admin | `ADMIN` (Safe in prod) | Grant / revoke roles | Write scores, sanctions, or escrow day-to-day |
| `_REGISTRY_KEEPER` | `REGISTRY_KEEPER` | Sanctions list (`commit` / `reveal` / emergency `setSanctioned`) | Publish scores, pause, touch fees |
| `_ORACLE_KEEPER` | `ORACLE_KEEPER` | Submit `updateScore` **with** a valid attestor signature | Sign the payload, sanction, retune thresholds |
| Attestor (not a manager role) | `ATTESTOR` (required; no default) | ECDSA-sign the score payload (hop + origin bound) | Submit the tx alone |
| `_HOOK_GOVERNOR` | `HOOK_GOVERNOR` | Thresholds, Chainlink `setPriceFeed`, trusted routers/multisigs, pause, attestor rotation, `setUnscoredThresholds` | Write scores or sanctions |

`ATTESTOR` must be distinct from governor, oracle keeper, and registry keeper. Deploy fails closed if it is missing or collides.

**FeeEscrow (own list)**

| Role | Can |
|---|---|
| Owner (`ADMIN` / `FEE_ESCROW_OWNER`) | Keepers (add 24h / revoke now), depositors (24h after bootstrap), auditors, tokens, LP fund, compliance reserve, `recoverBlocked` (≥7d floor, to reserve only) |
| Bootstrapper (deployer, one-shot) | `bootstrapDepositor(hook)` then cleared |
| Depositor (the hook) | `deposit` only |
| Escrow keeper | `releaseEarly` / `resolveCheckpoint2` / `releaseDefault` |
| Auditor | Read full escrow rows |

### Oracle latency (whitepaper §8.4)

Mitigations A–D elevate **ALLOW → FEE_OVERRIDE** (never soften an existing REVERT / FEE_OVERRIDE), except the never-scored **magnitude floor**, which may REVERT:

| Code | Signal | Outcome |
|---|---|---|
| A | Score never written (`updatedAt == 0`), assessed USD < $1,000 | FEE_OVERRIDE **3%** |
| A mid | Same, $1,000 ≤ assessed USD < $25,000 | FEE_OVERRIDE **8%** |
| A + magnitude | Same, assessed USD ≥ $25,000 (this swap + window USD, including across tokens) | **REVERT** (`UnscoredMagnitudeBlocked`) |
| A fail-closed | Never-scored and no Chainlink feed, stale feed, or bad answer | **REVERT** (`MagnitudeQuoteFailed`) |
| B | Score older than `stalenessThreshold` (default 5 minutes) + ≥1 settled swap already in the activity window | FEE_OVERRIDE 8%. First swap of a new window does not arm this. A healthy keeper stamps `updatedAt` again when the window ages, even if the score did not move. |
| C | Activity-window cap (`maxOpsInWindow`) | FEE_OVERRIDE |
| D | Inbound vs `lastKnownBalance` while oracle predates baseline, quoted to USD-8 | Relative (inbound USD > 50% of current USD) → FEE_OVERRIDE differential. Absolute (inbound USD ≥ $25,000) → **REVERT** `InflowMagnitudeBlocked`. **Skipped** when `updatedAt == 0` or there is no baseline |

Defaults: `unscoredFeeThreshold = 1_000e8` ($1,000); `unscoredRevertThreshold = 25_000e8` ($25,000); `stalenessThreshold = 5 minutes` (`DEFAULT_STALENESS`; same as local `MAX_SCORE_AGE` unless set); `priceStalenessThreshold = 3600`; `activityWindow = 1 hour`; `maxOpsInWindow = 3`. Those USD floors are **8 decimals** (Chainlink). Governor binds `token => AggregatorV3Interface` via `setPriceFeed` (`address(0)` = ETH/USD), retunes Floor B via `setStalenessThreshold` (1s–24h), and retunes Mitigation C via `setActivityWindow` (60s–7d, 1–100 ops). Missing or stale feed is fail-closed. This adds an external-oracle surface (manipulation, heartbeat lag) that native-unit floors did not have. Revert threshold `0` disables the hard block.

Published score 0 (`updatedAt != 0`) is confirmed-clean: magnitude REVERT does **not** apply to swap size of already-held funds.

Window volume is accumulated in USD-8 inside Mitigation C's activity window so ETH and USDC are not added as raw units. Small swaps that sum over $25,000 still REVERT (structuring).

Product paths: Wallet D (inflow, B, C, $25k) and Wallet E (USD bands, window, feed) in [`docs/Use_Case.md`](../docs/Use_Case.md).

REVERT does not emit a lasting log. Index custom errors on reverted txs: `SanctionHit`, `WalletBlocked` (score ≥ 71), `UnscoredMagnitudeBlocked`, `InflowMagnitudeBlocked`, `MagnitudeQuoteFailed`.

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

Deployer = Anvil account #0 (local defaults for admin / registry keeper / oracle keeper / hook governor unless overridden). Production **must** set:

| Env | Purpose |
|---|---|
| `ATTESTOR` | Required. Distinct ECDSA attestor. No default — missing value fails the script. |
| `ADMIN` or `FEE_ESCROW_OWNER` | FeeEscrow + AccessManager admin from genesis (Safe). Not the configurer EOA. |
| `LP_COMPENSATION_FUND` | Clean / early / default escrow destination. Defaults to the fee-escrow owner, not the deployer. |
| `COMPLIANCE_RESERVE` | Recovered Blocked (confirmed-illicit) destination. Production MUST set the authority wallet. Local default is a labeled placeholder, never the LP fund. |
| `MAX_SCORE_AGE` | Floor B `stalenessThreshold` at deploy. Script default is 5 minutes. If this is 0, the hook constructor falls back to `DEFAULT_STALENESS` (5 minutes). |
| `REGISTRY_KEEPER` / `ORACLE_KEEPER` / `HOOK_GOVERNOR` | Split keys. Deploy verifies they do not overlap. |

`bootstrapDepositor` runs in the same deploy tx so the first FEE_OVERRIDE `deposit` does not wait 24h.

After deploy, `_HOOK_GOVERNOR` **must** bind a Chainlink `AggregatorV3` per pool token (`setPriceFeed`; `address(0)` = ETH/USD). Never-scored magnitude and Mitigation D's absolute floor quote to USD-8 (`1_000e8` / `25_000e8`). A token with no feed, or a feed older than `priceStalenessThreshold` (default 3600s), fail-closes (`MagnitudeQuoteFailed`). This is an extra operational surface — see whitepaper §8.4.

Writes `contracts/deployments/31337.json` and copies to `packages/sdk/deployments/`.

The CREATE2 address mined by `Deploy.sol` changed versus earlier deploys: the flag bitmask now includes `BEFORE_ADD_LIQUIDITY_FLAG` and `BEFORE_REMOVE_LIQUIDITY_FLAG` in addition to the swap flags. An address mined with the previous bitmask will not match the hook's current permissions.

## Boundary

| Layer | Role |
|---|---|
| `apps/api` | Oracle Keeper — mock trail or real `updateScore` tx; defers D for latency demo |
| `contracts/` | On-chain ALLOW / FEE_OVERRIDE / REVERT + §8.4 floors + Chainlink USD magnitude |
| `packages/sdk` | Shared ABIs / addresses for api + frontend |
