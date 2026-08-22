# AML Hook · API (demo, no DB)

In-memory TypeScript API that owns the demo ledger and the **off-chain oracle COA** (Compliance Officer Agent mock).

State lives in process memory — **resets when the server restarts**. No Postgres.

**Oracle COA (MOCK_MODE):** scores and Opinion are produced by `apps/api/src/oracle/` using the skill pack in [`agents/oracle-coa/`](../../agents/oracle-coa/). Facts come from the N-hop ledger + swap/event trail. There are **no live calls** to Anthropic, OpenSanctions, Etherscan, GoPlus, Chainalysis, TRM, or OFAC APIs.

**FEE_OVERRIDE settlement (aligned with contracts):** the COA publishes `recommendedFeeBps` as total intended friction. On-chain, the pool keeps its standard fee; `afterSwap` takes the differential into `FeeEscrow`. Opinion copy must not describe settlement as `lpFeeOverride`.

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
| `GET` | `/wallets/:id` | One wallet (`A`–`E`) + quote |
| `GET` | `/wallets/:id/compliance` | **Oracle opinion** for Opinion UI |
| `GET` | `/wallets/:id/quote` | USDC→ETH quote (`?amountUsd=1000`). Same policy as on-chain: A–E, B/C floors, D $25k revert, E window + feed |
| `GET` | `/oracle` | All cached ScoreResults |
| `GET` | `/oracle/:id` | ScoreResult + opinion for one wallet |
| `POST` | `/oracle/:id/catch-up` | Publish deferred keeper score (Wallet D latency path) |
| `GET` | `/oracle/publishes` | Keeper `updateScore` trail (mock or rpc) |
| `POST` | `/transfers` | P2P USDC → hop update → oracle reevaluate (tainted inbound to D defers keeper) |
| `POST` | `/swaps` | Settle swap → event → oracle reevaluate (D pending → catch-up ~65) |
| `POST` | `/demo/elapse` | Advance demo clock (`{ seconds: 121 }` → Mitigation B) |
| `POST` | `/demo/price-feed` | Bind / unbind USDC/USD (`{ bound: false }` → `MagnitudeQuoteFailed`) |
| `GET` | `/transfers` | Transfer history |
| `GET` | `/events` | Simulated hook trail |
| `POST` | `/reset` | Reseed A–E + oracle baseline (E stays unpublished) |

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

### Example — Wallet D inflow (clean C→D, no hop)

```bash
# C still clean: credits D without a hop. Inflow vs last baseline → 8%.
curl -X POST http://localhost:4000/transfers ^
  -H "Content-Type: application/json" ^
  -d "{\"from\":\"C\",\"to\":\"D\",\"amountUsd\":10000}"

curl http://localhost:4000/wallets/D/quote
# → FEE_OVERRIDE · feeBps 800 · latencyMitigation INFLOW_HEURISTIC · hopDistance null

curl -X POST http://localhost:4000/swaps ^
  -H "Content-Type: application/json" ^
  -d "{\"walletId\":\"D\",\"amountUsd\":1000}"
# → settles at 8%; D stays score 0 (no hop to publish)
```

## Use-case baseline

- **A** exploit → REVERT  
- **B** and **C** both start clean (ALLOW 0.30%)  
- **D** starts with 5,000 USDC and a published score 0  
- Receive from **A** → ~65 / 8% (1-hop)  
- Receive from the other after it was tainted by A → ~42 / 3% (2-hop); closer hop wins  
- Clean **C → D** (or B while clean) is **not** a hop: ~10k → **FEE_OVERRIDE 8%** (inflow); ≥ $25,000 → `InflowMagnitudeBlocked`  
- **Wallet E** (no oracle row): on-chain Chainlink USD-8 bands — < $1,000 → 3%; $1,000–$24,999 → 8%; ≥ $25,000 → `UnscoredMagnitudeBlocked`; no/stale feed → `MagnitudeQuoteFailed`  
- **1 ETH = 1,000 USDC** (demo ledger). On-chain floors are USD-8 (`1_000e8` / `25_000e8`), not native ether.

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