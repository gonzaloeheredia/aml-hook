# AML Hook · Backend (demo, no DB)

In-memory TypeScript API that owns the demo ledger and live compliance dictamen.

State lives in process memory — **resets when the server restarts**. No Postgres.

**Simulated only:** risk scores and Layer-1 “sanctions” wording in `/compliance` are derived from the in-memory N-hop ledger (use-case A/B/C). There are **no live calls** to OpenSanctions, Etherscan, GoPlus, Chainalysis, TRM, or OFAC APIs — those names appear as product intent / copy, not as integrations in this demo.

## What it replaces (conceptually)

| Frontend today | Backend endpoint |
|---|---|
| `simWallets` / `initialSimWallets` | `GET /wallets`, `GET /wallets/:id` |
| `applyTransfer` | `POST /transfers` |
| `applyPoolSwap` + quote | `GET /wallets/:id/quote`, `POST /swaps` |
| `withHopOverlay` / agent opinion | `GET /wallets/:id/compliance` |

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
| `GET` | `/health` | Liveness + mode (`in-memory`) |
| `GET` | `/wallets` | All wallets + live score/decision |
| `GET` | `/wallets/:id` | One wallet (`A` \| `B` \| `C`) + quote |
| `GET` | `/wallets/:id/compliance` | **Live dictamen** (technical opinion, SAR annex, decision record) |
| `GET` | `/wallets/:id/quote` | USDC→ETH quote (`?amountUsd=1000`) |
| `POST` | `/transfers` | P2P USDC `{ "from":"A", "to":"B", "amountUsd":10000 }` |
| `POST` | `/swaps` | Settle pool swap `{ "walletId":"C", "amountUsd":1000 }` |
| `GET` | `/transfers` | Transfer history |
| `GET` | `/events` | Simulated hook trail (`SwapObserved` in afterSwap; `WalletBlocked` when REVERT blocks beforeSwap) |
| `POST` | `/reset` | Reseed A/B/C to use-case baseline |

### Example — compliance dictamen

```bash
curl http://localhost:4000/wallets/C/compliance
```

### Example — contaminate then re-read opinion

```bash
curl -X POST http://localhost:4000/transfers ^
  -H "Content-Type: application/json" ^
  -d "{\"from\":\"A\",\"to\":\"B\",\"amountUsd\":10000}"

curl http://localhost:4000/wallets/B/compliance
```

## Use-case baseline

- **A** exploit → REVERT  
- **B** and **C** both start clean (ALLOW 0.30%)  
- Receive from **A** → ~65 / 8% (1-hop)  
- Receive from the other after it was tainted by A → ~42 / 3% (2-hop); closer hop wins  
- **1 ETH = 1,000 USDC**

### Example — symmetric contamination

```bash
# C starts clean
curl http://localhost:4000/wallets/C/compliance

# A→C → C score ≈ 65
curl -X POST http://localhost:4000/transfers -H "Content-Type: application/json" -d "{\"from\":\"A\",\"to\":\"C\",\"amountUsd\":10000}"
curl http://localhost:4000/wallets/C/compliance

# Reset, then A→B→C → C score ≈ 42
curl -X POST http://localhost:4000/reset
curl -X POST http://localhost:4000/transfers -H "Content-Type: application/json" -d "{\"from\":\"A\",\"to\":\"B\",\"amountUsd\":10000}"
curl -X POST http://localhost:4000/transfers -H "Content-Type: application/json" -d "{\"from\":\"B\",\"to\":\"C\",\"amountUsd\":5000}"
curl http://localhost:4000/wallets/C/compliance
```

## Next step (later)

Wire `frontend/` already uses these endpoints (`NEXT_PUBLIC_API_URL`). Optionally swap the in-memory store for Postgres later.
