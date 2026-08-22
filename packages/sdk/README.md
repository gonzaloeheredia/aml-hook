# @aml-hook/sdk

Shared ABIs, types, and deployment addresses for AML Hook.

## After local deploy

```bash
# repo root
node scripts/deploy-local.mjs
# or: npm run deploy:local
```

Writes:

- `packages/sdk/deployments/31337.json` — AccessManager, L1/L2/L3, AmlHook, role holders, poolManager
- `apps/api/.env.local` — oracle keeper RPC env (`SCORE_SOURCE=onchain`)

```ts
import {
  complianceOracleAbi,
  amlHookAbi,
  getDeployment,
  getOracleKeeperAddress,
  ANVIL_KEEPER_PRIVATE_KEY,
} from "@aml-hook/sdk";

const d = getDeployment(31337);
// d.AccessManager, d.ComplianceOracle, d.AmlHook, …
// getOracleKeeperAddress(d) → key that must hold `_ORACLE_KEEPER`
```

`ComplianceOracle.updateScore` is AccessManaged: the API's `KEEPER_PRIVATE_KEY` must be the granted oracle keeper (Anvil #0 by default on local Deploy).

After deploy, `_HOOK_GOVERNOR` must call `AmlHook.setPriceFeed(token, aggregator)` for each pool currency (`address(0)` = ETH/USD). Never-scored magnitude floors are USD-8 (`1_000e8` / `25_000e8`). No feed or a stale feed fail-closes.
