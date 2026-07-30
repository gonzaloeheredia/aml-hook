# AML Hook · Backend (demo, no DB)

In-memory TypeScript API that owns the demo ledger and the **off-chain oracle COA** (Compliance Officer Agent mock).

State lives in process memory — **resets when the server restarts**. No Postgres.

**Oracle COA (MOCK_MODE):** scores and Opinion are produced by `backend/src/oracle/` using the skill pack in [`agents/oracle-coa/`](../agents/oracle-coa/). Facts come from the N-hop ledger + swap/event trail. There are **no live calls** to Anthropic, OpenSanctions, Etherscan, GoPlus, Chainalysis, TRM, or OFAC APIs.

## What it replaces (conceptually)

| Frontend today | Backend endpoint |
|---|---|
| `simWallets` / `initialSimWallets` | `GET /wallets`, `GET /wallets/:id` |
| `applyTransfer` | `POST /transfers` (+ oracle reevaluate) |
| `applyPoolSwap` + quote | `GET /wallets/:id/quote`, `POST /swaps` (+ afterSwap oracle) |
| `withHopOverlay` / agent opinion | `GET /wallets/:id/compliance` (oracle opinion) |

## Run

```bash
cd backend
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
| `POST` | `/transfers` | P2P USDC → hop update → **oracle reevaluate** from/to |
| `POST` | `/swaps` | Settle swap → event → **oracle reevaluate** |
| `GET` | `/transfers` | Transfer history |
| `GET` | `/events` | Simulated hook trail |
| `POST` | `/reset` | Reseed A/B/C + oracle baseline |

### Oracle flow

```
P2P transfer or afterSwap event
        │
        ▼
  oracle COA (skills in agents/oracle-coa)
        │
        ▼
  in-memory score store  ←── next beforeSwap / quote reads this
        │
        ▼
  opinion → GET /compliance → Opinion stage
```

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

## Next step (later)

Wire `ComplianceOracle` + `AMLHook` contracts; keep the same oracle COA as the off-chain writer that signs scores on-chain. Optionally swap MOCK_MODE for a live Claude loop using the same skills.
