# AML Hook · API (demo, no DB)

In-memory TypeScript API that owns the demo ledger and the **off-chain oracle COA** (Compliance Officer Agent mock).

State lives in process memory — **resets when the server restarts**. No Postgres.

**Oracle COA (MOCK_MODE):** scores and Opinion are produced by `apps/api/src/oracle/` using the skill pack in [`agents/oracle-coa/`](../../agents/oracle-coa/). Facts come from the N-hop ledger + swap/event trail. There are **no live calls** to Anthropic, OpenSanctions, Etherscan, GoPlus, Chainalysis, TRM, or OFAC APIs.

## What it replaces (conceptually)

| Frontend today | API endpoint |
|---|---|
| `simWallets` / `initialSimWallets` | `GET /wallets`, `GET /wallets/:id` |
| `applyTransfer` | `POST /transfers` (+ oracle reevaluate) |
| `applyPoolSwap` + quote | `GET /wallets/:id/quote`, `POST /swaps` (+ afterSwap oracle) |
| `withHopOverlay` / agent opinion | `GET /wallets/:id/compliance` (oracle opinion) |

## Run

```bash
cd apps/api
npm install
npm run dev
```

Default: [http://localhost:4000](http://localhost:4000)

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness + mode (`in-memory`, `oracle: coa-mock`) |
| `GET` | `/wallets` | All wallets + live oracle score/decision |
| `GET` | `/wallets/:id` | One wallet (`A`–`D`) + quote |
| `GET` | `/wallets/:id/compliance` | **Oracle opinion** for Opinion UI |
| `GET` | `/wallets/:id/quote` | USDC→ETH quote (`?amountUsd=1000`); D may show inflow FEE_OVERRIDE 8% |
| `GET` | `/oracle` | All cached ScoreResults |
| `GET` | `/oracle/:id` | ScoreResult + opinion for one wallet |
| `POST` | `/oracle/:id/catch-up` | Publish deferred keeper score (Wallet D latency path) |
| `GET` | `/oracle/publishes` | Keeper `updateScore` trail (mock or rpc) |
| `POST` | `/transfers` | P2P USDC → hop update → oracle reevaluate (`A→D` defers keeper) |
| `POST` | `/swaps` | Settle swap → event → oracle reevaluate (D pending → catch-up ~65) |
| `GET` | `/transfers` | Transfer history |
| `GET` | `/events` | Simulated hook trail |
| `POST` | `/reset` | Reseed A–D + oracle baseline |

### Oracle flow

```
P2P transfer or afterSwap / WalletBlocked
        │
        ▼
  oracle COA (skills in agents/oracle-coa)
        │
        ├─► in-memory score store  ←── demo beforeSwap / quote reads this
        │
        └─► ComplianceOracle.updateScore
              · mock (default): recorded in GET /oracle/publishes
              · rpc: set ORACLE_RPC_URL + COMPLIANCE_ORACLE_ADDRESS + KEEPER_PRIVATE_KEY
        │
        ▼
  opinion → GET /compliance → Opinion stage
```

See [`.env.example`](.env.example) for on-chain keeper env vars.

### Example — compliance opinion (oracle-backed)

```bash
curl http://localhost:4000/wallets/C/compliance
curl http://localhost:4000/oracle/B
```

### Example — contaminate then re-read opinion

```bash
curl -X POST http://localhost:4000/transfers ^
  -H "Content-Type: application/json" ^
  -d "{\"from\":\"A\",\"to\":\"B\",\"amountUsd\":10000}"

curl http://localhost:4000/oracle/B
curl http://localhost:4000/wallets/B/compliance
```

### Example — Wallet D latency / inflow (§3.8)

```bash
# A→D: ledger hop updates, but keeper updateScore is deferred (stale score 0)
curl -X POST http://localhost:4000/transfers ^
  -H "Content-Type: application/json" ^
  -d "{\"from\":\"A\",\"to\":\"D\",\"amountUsd\":10000}"

curl http://localhost:4000/wallets/D/quote
# → FEE_OVERRIDE · feeBps 800 · latencyMitigation INFLOW_HEURISTIC · keeperPending true

curl -X POST http://localhost:4000/swaps ^
  -H "Content-Type: application/json" ^
  -d "{\"walletId\":\"D\",\"amountUsd\":1000}"
# → settles at 8%; response.keeperCatchUp.score ≈ 65
```

## Use-case baseline

- **A** exploit → REVERT  
- **B** and **C** both start clean (ALLOW 0.30%)  
- **D** starts clean with 0 USDC — latency / inflow path (§3.8)  
- Receive from **A** → ~65 / 8% (1-hop)  
- Receive from the other after it was tainted by A → ~42 / 3% (2-hop); closer hop wins  
- **A → D** defers keeper `updateScore`; D swap under stale score 0 → **FEE_OVERRIDE 8%** (inflow); catch-up → score **65**  
- **1 ETH = 1,000 USDC**

## On-chain keeper + beforeSwap score read

```bash
# repo root — Anvil + Deploy (AccessManager + L1/L2/L3 + hook) + apps/api/.env.local
npm run deploy:local

# then restart API
cd apps/api && npm run dev
```

`.env.local` sets `ORACLE_RPC_*`, `COMPLIANCE_ORACLE_ADDRESS`, `KEEPER_PRIVATE_KEY`, `SCORE_SOURCE=onchain`.

Local deploy defaults Anvil account #0 for **admin**, **registry keeper**, **oracle keeper** and **hook governor**. The API's `KEEPER_PRIVATE_KEY` must be a key that holds AccessManager role `_ORACLE_KEEPER` (role id `2`) or `updateScore` reverts with `AccessManagedUnauthorized`.

| Mode | Behavior |
|---|---|
| no rpc env | publish **mock**; quotes use **memory** COA |
| rpc + `SCORE_SOURCE=onchain` | publish **tx**; quotes/swaps read **ComplianceOracle.getRisk** (if `updatedAt>0`) |

Check: `GET /health` → `scoreSource` / `publisher.mode`.  
Trail: `GET /oracle/publishes` → `status: "submitted"` + `txHash`.

See also [`contracts/README.md`](../../contracts/README.md) for `script/Deploy.sol` env overrides (`ORACLE_KEEPER`, `HOOK_GOVERNOR`, …).