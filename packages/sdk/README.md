# @aml-hook/sdk

Shared ABIs, types, and deployment addresses for AML Hook.

## After local deploy

```bash
# repo root
node scripts/deploy-local.mjs
# or: npm run deploy:local
```

Writes:

- `packages/sdk/deployments/31337.json` — AccessManager, L1/L2/L3, AmlHook, FeeEscrow, ComplianceTreasury, `feeToken` (MockUSDC), `wethToken` (MockWETH), `usdFeed` / `ethUsdFeed`, demo wallets A–E (Anvil #1–#5), attestor, role holders (`hookGovernor`, `complianceOfficer`, keepers), poolManager. Wallet F is a live OFAC SDN ETH address bound by the API, not this JSON.
- Sepolia (`11155111`) is **not** in this package. `getDeployment(11155111)` returns `null`. Use [`contracts/deployments/11155111.json`](../../contracts/deployments/11155111.json) and [`docs/Sepolia.md`](../../docs/Sepolia.md).
- `apps/api/.env.local` — RPC, hook, oracle, escrow, fee token, `WETH_TOKEN_ADDRESS`, feeds, `COMPLIANCE_TREASURY_ADDRESS` / `COMPLIANCE_RESERVE` / `LP_COMPENSATION_FUND`, keeper (Anvil #0), attestor (Anvil #9)

```ts
import {
  complianceOracleAbi,
  amlHookAbi,
  getDeployment,
  getOracleKeeperAddress,
  ANVIL_KEEPER_PRIVATE_KEY,
} from "@aml-hook/sdk";

const d = getDeployment(31337);
// d.AccessManager, d.ComplianceOracle, d.AmlHook, d.FeeEscrow, d.feeToken, d.wethToken, …
// getOracleKeeperAddress(d) → key that must hold `_ORACLE_KEEPER`
```

`ComplianceOracle.updateScore` is AccessManaged: the API's `KEEPER_PRIVATE_KEY` must be the granted oracle keeper (Anvil #0 by default on local Deploy). The attestor (Anvil #9 locally) signs `attestationHash`. The COA emits `finalScore` and `recommendedFeeBps`; the keeper only publishes that row.

Local Anvil deploy binds `MockUsdFeed` for the fee token ($1) and ETH ($1000). On a live chain Deploy binds official Chainlink ETH/USD (native + WETH) and USDC/USD. `_HOOK_GOVERNOR` can retune extras via `AmlHook.setPriceFeed(token, aggregator)` (`address(0)` = ETH/USD). `_COMPLIANCE_OFFICER` proposes then confirms USD floors and floor fees (48h). Never-scored magnitude floors are USD-8 (`1_000e8` / `15_000e8`). Liquidity adds reuse those cuts via `LpPolicyLib` (Floor A / C / D; C sums adds, not swaps). If `lastFx` is younger than 30 minutes (`FX_HOT_TTL`) the swap does not call Chainlink; otherwise one round per token. A missing live round uses `lastFx` (max 24h). No live round and no cache within 24h fail-closes.
