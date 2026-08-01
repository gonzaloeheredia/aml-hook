# @aml-hook/sdk

Shared ABIs, types, and deployment addresses for AML Hook.

## After local deploy

```bash
# repo root
node scripts/deploy-local.mjs
```

Writes:

- `packages/sdk/deployments/31337.json` — contract addresses on Anvil
- `apps/api/.env.local` — keeper RPC env (`SCORE_SOURCE=onchain`)

```ts
import {
  complianceOracleAbi,
  amlHookAbi,
  getDeployment,
  ANVIL_KEEPER_PRIVATE_KEY,
} from "@aml-hook/sdk";

const d = getDeployment(31337);
// d.ComplianceOracle, d.AmlHook, …
```
