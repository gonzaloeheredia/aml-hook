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
| `GET` | `/wallets/:id` | One wallet (`A` \| `B` \| `C`) + quote |
| `GET` | `/wallets/:id/compliance` | **Oracle opinion** for Opinion UI |
| `GET` | `/wallets/:id/quote` | USDC→ETH quote (`?amountUsd=1000`) |
| `GET` | `/oracle` | All cached ScoreResults |
| `GET` | `/oracle/:id` | ScoreResult + opinion for one wallet |
| `GET` | `/oracle/publishes` | Keeper `updateScore` trail (mock or rpc) |
| `POST` | `/transfers` | P2P USDC → hop update → **oracle reevaluate** from/to |
| `POST` | `/swaps` | Settle swap → event → **oracle reevaluate** |
| `GET` | `/transfers` | Transfer history |
| `GET` | `/events` | Simulated hook trail |
| `POST` | `/reset` | Reseed A/B/C + oracle baseline |

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

## Use-case baseline

- **A** exploit → REVERT  
- **B** and **C** both start clean (ALLOW 0.30%)  
- Receive from **A** → ~65 / 8% (1-hop)  
- Receive from the other after it was tainted by A → ~42 / 3% (2-hop); closer hop wins  
- **1 ETH = 1,000 USDC**

## On-chain keeper + beforeSwap score read

```bash
# repo root — Anvil + deploy + apps/api/.env.local
npm run deploy:local

# then restart API
cd apps/api && npm run dev
```

`.env.local` sets `ORACLE_RPC_*`, `COMPLIANCE_ORACLE_ADDRESS`, `KEEPER_PRIVATE_KEY`, `SCORE_SOURCE=onchain`.

| Mode | Behavior |
|---|---|
| no rpc env | publish **mock**; quotes use **memory** COA |
| rpc + `SCORE_SOURCE=onchain` | publish **tx**; quotes/swaps read **ComplianceOracle.getRisk** (if `updatedAt>0`) |

Check: `GET /health` → `scoreSource` / `publisher.mode`.  
Trail: `GET /oracle/publishes` → `status: "submitted"` + `txHash`.
