# @aml-hook/sdk

Shared ABIs, types, and deployment addresses for AML Hook.

## After local deploy

```bash
# repo root
node scripts/deploy-local.mjs
# or: npm run deploy:local
```

Writes:

- `packages/sdk/deployments/31337.json` — AccessManager, L1/L2/L3, AmlHook, FeeEscrow, `feeToken`, `usdFeed` / `ethUsdFeed`, demo wallets A–E, attestor, role holders, poolManager
- `apps/api/.env.local` — RPC, hook, oracle, escrow, token, feeds, keeper (Anvil #0), attestor (Anvil #9)

```ts
import {
  complianceOracleAbi,
  amlHookAbi,
  getDeployment,
  getOracleKeeperAddress,
  ANVIL_KEEPER_PRIVATE_KEY,
} from "@aml-hook/sdk";

const d = getDeployment(31337);
// d.AccessManager, d.ComplianceOracle, d.AmlHook, d.FeeEscrow, d.feeToken, …
// getOracleKeeperAddress(d) → key that must hold `_ORACLE_KEEPER`
```

`ComplianceOracle.updateScore` is AccessManaged: the API's `KEEPER_PRIVATE_KEY` must be the granted oracle keeper (Anvil #0 by default on local Deploy). The attestor (Anvil #9 locally) signs `attestationHash`.

Local deploy binds `MockUsdFeed` for the fee token ($1) and ETH ($1000). `_HOOK_GOVERNOR` can retune via `AmlHook.setPriceFeed(token, aggregator)` (`address(0)` = ETH/USD). Never-scored magnitude floors are USD-8 (`1_000e8` / `25_000e8`). No feed or a stale feed fail-closes.
