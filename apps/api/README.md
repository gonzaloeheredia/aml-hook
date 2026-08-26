# AML Hook · API (Anvil adapter)

TypeScript API that talks to the local stack. It does not own the ledger. Balances, scores, quotes, and FeeEscrow rows live on Anvil. Without `npm run deploy:local` every chain route returns `503` `{ error: "deploy_local" }`.

**Oracle COA:** with `ANTHROPIC_API_KEY` in `apps/api/.env`, Claude emits `finalScore`, `recommendedFeeBps`, and the Opinion (tools: `consult_skill` / `uhi10-use-case`, `search_regulations`, `screen_ofac`). The keeper writes `ComplianceOracle`; quotes and swaps read `AmlHook.previewSwap`. On every evaluation the COA screens the subject against the live OFAC SDN ETH list and, on an exact match, writes `SanctionRegistry` — the swap still only reads that mapping. Tests and `OFAC_LIVE=0` skip Treasury. There are still **no** live calls to OpenSanctions, Etherscan, GoPlus, Chainalysis, or TRM. Seed waits on Claude when the key is set (A–D and F). E stays unpublished. The 3-minute keeper tick only stamps the last score (no Claude). If the agent is down, that tick still keeps `updatedAt` inside Floor B's 5-minute window. If both are down, Floor B fires.

**Quotes:** `GET /wallets/:id/quote` and swap settlement call `AmlHook.previewSwap` — the same L1→L3 path `beforeSwap` uses. There is no TypeScript policy fallback.

**FEE_OVERRIDE settlement:** the COA publishes `recommendedFeeBps` as total intended friction. A demo swap is `previewSwap` + `observeSwap` (activity / baseline / `SwapObserved`). On FEE_OVERRIDE the API mints the extra slice and calls `FeeEscrow.deposit`. That is not a live Uniswap `PoolManager` fill. A later clean exit goes to the LP compensation fund. Checkpoint 2 reads the on-chain list and oracle (score ≥ 71). A confirmed-illicit row is recovered to ComplianceTreasury `ILLICIT_RISK_FEE` only (whitepaper §8.3).

The keeper writes when the ALLOW / FEE / REVERT tier or the 3% / 8% fee band changes, **or** on a 3-minute heartbeat (same score, new `updatedAt`), **or** when the last write is at least as old as Floor B (`STALENESS_MS` = 5 minutes). That freshness stamp stops a stable clean wallet from looking stale. Floor B: stale + no swap yet this hour → 3%; stale + prior activity → pass / 3% / 8% by swap+window USD. `updateScore` is signed by Anvil **#9** (attestor) over `attestationHash`. An empty signature is rejected.

## What it replaces (conceptually)

| Frontend today | API endpoint |
|---|---|
| `simWallets` / `initialSimWallets` | `GET /wallets`, `GET /wallets/:id` |
| `applyTransfer` | `POST /transfers` (ERC-20 `transfer` on Anvil + oracle reevaluate) |
| quote / swap | `GET /wallets/:id/quote`, `POST /swaps` (`previewSwap` + `observeSwap` + escrow deposit) |
| agent opinion | `GET /wallets/:id/compliance` (oracle opinion) |

## Run

```bash
# repo root — Anvil + Deploy + apps/api/.env.local
npm run deploy:local

cd apps/api
npm install
npm run dev
```

Default: [http://localhost:4000](http://localhost:4000)

Restart the API after every `deploy:local` so it loads `.env.local`.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | `mode: "anvil"`, `agent.score` / `agent.opinion`, `keeperTickMs`, `chain.ok` |
| `GET` | `/wallets` | All wallets + live `previewSwap` quote |
| `GET` | `/wallets/:id` | One wallet (`A`–`E`) + quote |
| `GET` | `/wallets/:id/compliance` | **Oracle opinion** for Opinion UI |
| `GET` | `/wallets/:id/quote` | USDC→ETH quote (`?amountUsd=1000`). Same policy as on-chain |
| `GET` | `/oracle` | All cached ScoreResults |
| `GET` | `/oracle/:id` | ScoreResult + opinion for one wallet |
| `POST` | `/oracle/:id/catch-up` | Publish deferred keeper score (Wallet D latency path) |
| `GET` | `/oracle/publishes` | Keeper `updateScore` trail (`txHash`) |
| `POST` | `/transfers` | P2P USDC on Anvil → wait for agent score → keeper publish (tainted inbound to D defers keeper) |
| `POST` | `/swaps` | `previewSwap` + `observeSwap` + wait for agent + FeeEscrow deposit on FEE_OVERRIDE |
| `POST` | `/demo/elapse` | `evm_increaseTime` + `evm_mine` (`{ seconds: 301 }` → Floor B) |
| `POST` | `/demo/price-feed` | Bind / unbind USDC/USD (`{ bound: false }` → silent `lastFx` if quoted in the last 30 min; `PriceFallbackUsed` until 24h after that; else `MagnitudeQuoteFailed`) |
| `GET` | `/escrow` | Live FeeEscrow rows |
| `POST` | `/escrow/:id/checkpoint2` | Checkpoint 2 reads oracle/list (no keeper bool) |
| `POST` | `/escrow/:id/recover` | Recover Blocked → compliance reserve |
| `GET` | `/transfers` | Transfer history |
| `GET` | `/events` | Hook trail (`SwapObserved` / blocked) |
| `POST` | `/reset` | Mint + `syncBaseline` + agent seed A–D (Claude wait when key set; E unpublished) |

### Oracle flow

```
P2P transfer or afterSwap / WalletBlocked
        │
        ▼
  oracle COA (skills in agents/oracle-coa)
        │
        ├─► OFAC SDN ETH screen → SanctionRegistry.setSanctioned on match
        ├─► Claude (or skill interpreter) → cache
        │
        └─► ComplianceOracle.updateScore (signed RPC, or fail)
              keeper = Anvil #0 · attestor = Anvil #9
        │
        ▼
  quote / swap → AmlHook.previewSwap  (L1 reads the mapping only)
  opinion → GET /compliance → Opinion stage (includes live SDN result)
```

See [`.env.example`](.env.example) for required Anvil env vars. Put `ANTHROPIC_API_KEY` in `apps/api/.env` (gitignored). Do not put it in `.env.example` or `.env.local`.

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
# C still clean: credits D without a hop. Inflow vs last baseline → 3%.
curl -X POST http://localhost:4000/transfers ^
  -H "Content-Type: application/json" ^
  -d "{\"from\":\"C\",\"to\":\"D\",\"amountUsd\":10000}"

curl http://localhost:4000/wallets/D/quote
# → FEE_OVERRIDE · feeBps 300 · latencyMitigation INFLOW_HEURISTIC · hopDistance null

curl -X POST http://localhost:4000/swaps ^
  -H "Content-Type: application/json" ^
  -d "{\"walletId\":\"D\",\"amountUsd\":1000}"
# → observeSwap + FeeEscrow.deposit; D stays score 0 (no hop to publish)
```

## Use-case baseline

- **A** confirmed exploit, score 100 (not OFAC-listed) → `WalletBlocked` on pool; P2P still contaminates B/C/D. Do not fund E from A.  
- **B** and **C** both start clean (ALLOW 0.30%). **C** (50,000 USDC) funds E (unknown, no hop) or D (inflow).  
- **D** starts with 5,000 USDC and a published score 0  
- Receive from **A** → ~65 / 8% (1-hop)  
- Receive from the other after it was tainted by A → ~42 / 3% (2-hop); closer hop wins  
- Clean **C → D** (or B while clean) is **not** a hop: ~10k → **FEE_OVERRIDE 3%** (inflow); ≥ $15,000 → **FEE_OVERRIDE 8%**  
- **Wallet E** (no oracle row, starts empty): fund from **C** (no hop). Floor A is this swap; Floor D is the bag C sent; stricter fee wins. C→E $500 → 3%; $10k then $1k swap → 8% (A mid); $15k bag → 8% on a small swap (D); this swap ≥ $15,000 → `UnscoredMagnitudeBlocked`; 24h sum → `DailyAggregationBlocked`; no live feed uses `lastFx` (silent under 30 min; `PriceFallbackUsed` until 24h after that); never quoted or cache > 24h → `MagnitudeQuoteFailed`  
- **1 ETH = 1,000 USDC** on Anvil only (`MockUsdFeed` at local deploy). Live Deploy binds official Chainlink ETH/USD and USDC/USD. On-chain floors are USD-8 (`1_000e8` / `15_000e8`), not native ether. `_COMPLIANCE_OFFICER` can retune those floors after a 48h confirm.

## Anvil identities + keeper

```bash
# repo root
npm run deploy:local
cd apps/api
npm run dev
```

`.env.local` (from `scripts/sync-deployment.mjs`) sets RPC, hook, oracle, FeeEscrow, fee token, feeds, `COMPLIANCE_TREASURY_ADDRESS` / `COMPLIANCE_RESERVE` / `LP_COMPENSATION_FUND`, `KEEPER_PRIVATE_KEY` (Anvil **#0**), and `ATTESTOR_PRIVATE_KEY` (Anvil **#9**).

| Account | Role |
|---|---|
| Anvil #0 | Admin / registry keeper / oracle keeper / hook governor / compliance officer / FeeEscrow owner |
| Anvil #1–#5 | Demo wallets A–E. Keys stay on the API |
| Live OFAC SDN ETH | Wallet F. No Anvil key. COA writes `SanctionRegistry`; swap → `SanctionHit` |
| Anvil #9 | Distinct attestor. Signs `attestationHash` |

`KEEPER_PRIVATE_KEY` must hold AccessManager role `_ORACLE_KEEPER` (role id `2`) or `updateScore` reverts with `AccessManagedUnauthorized`. `ATTESTOR_PRIVATE_KEY` must be the oracle attestor or the signature is rejected.

Check: `GET /health` → `ok` / `mode: "anvil"` / `chain.ok`.  
Trail: `GET /oracle/publishes` → `status: "submitted"` + `txHash`.

See also [`contracts/README.md`](../../contracts/README.md) for `script/Deploy.sol` env overrides (`ORACLE_KEEPER`, `HOOK_GOVERNOR`, `COMPLIANCE_OFFICER`, `ATTESTOR`, …).
